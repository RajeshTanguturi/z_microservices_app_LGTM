#!/usr/bin/env bash

set -euo pipefail

#############################################
# CONFIGURATION
#############################################

CLUSTER_NAME="microservices-eks"
AWS_REGION="us-east-1"

EBS_CSI_ROLE_NAME="AmazonEKS_EBS_CSI_DriverRole"
EBS_CSI_ADDON="aws-ebs-csi-driver"
EBS_CSI_VERSION="v1.65.0-eksbuild.1"

STORAGE_CLASS="gp3"

#############################################
# COLORS / HELPERS
#############################################

info() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

error() {
    echo
    echo "ERROR: $1"
    exit 1
}

#############################################
# CHECK PREREQUISITES
#############################################

info "Checking prerequisites"

command -v aws >/dev/null 2>&1 || error "AWS CLI not installed"
command -v kubectl >/dev/null 2>&1 || error "kubectl not installed"
command -v helm >/dev/null 2>&1 || error "Helm not installed"

#############################################
# VERIFY AWS IDENTITY
#############################################

info "Checking AWS identity"

aws sts get-caller-identity >/dev/null \
    || error "AWS credentials are not configured"

#############################################
# UPDATE KUBECONFIG
#############################################

info "Updating kubeconfig"

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME"

#############################################
# VERIFY CLUSTER
#############################################

info "Checking EKS cluster"

K8S_VERSION=$(aws eks describe-cluster \
    --name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.version' \
    --output text)

echo "Kubernetes version: $K8S_VERSION"

if [[ "$K8S_VERSION" != "1.36" ]]; then
    error "Expected Kubernetes 1.36, found $K8S_VERSION"
fi

#############################################
# ENSURE POD IDENTITY AGENT
#############################################

info "Checking EKS Pod Identity Agent"

if aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --addon-name eks-pod-identity-agent >/dev/null 2>&1
then
    echo "Pod Identity Agent already installed."
else
    echo "Installing Pod Identity Agent..."

    aws eks create-addon \
        --cluster-name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --addon-name eks-pod-identity-agent \
        --resolve-conflicts OVERWRITE
fi

#############################################
# IAM ROLE
#############################################

info "Checking EBS CSI IAM role"

if aws iam get-role \
    --role-name "$EBS_CSI_ROLE_NAME" >/dev/null 2>&1
then
    echo "IAM role already exists."
else

    echo "Creating IAM role..."

    cat > /tmp/ebs-csi-trust-policy.json <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

    aws iam create-role \
        --role-name "$EBS_CSI_ROLE_NAME" \
        --assume-role-policy-document \
        file:///tmp/ebs-csi-trust-policy.json
fi

#############################################
# CONFIGURE POD IDENTITY TRUST
#############################################

info "Configuring IAM trust policy for EKS Pod Identity"

cat > /tmp/ebs-csi-trust-policy.json <<'EOF'
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

aws iam update-assume-role-policy \
    --role-name "$EBS_CSI_ROLE_NAME" \
    --policy-document file:///tmp/ebs-csi-trust-policy.json

#############################################
# ATTACH EBS POLICY
#############################################

info "Checking EBS CSI IAM policy"

EBS_POLICY_ARN="arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"

if aws iam list-attached-role-policies \
    --role-name "$EBS_CSI_ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='$EBS_POLICY_ARN'].PolicyArn" \
    --output text | grep -q "$EBS_POLICY_ARN"
then
    echo "AmazonEBSCSIDriverPolicy already attached."
else

    echo "Attaching AmazonEBSCSIDriverPolicy..."

    aws iam attach-role-policy \
        --role-name "$EBS_CSI_ROLE_NAME" \
        --policy-arn "$EBS_POLICY_ARN"
fi

#############################################
# ROLE ARN
#############################################

EBS_CSI_ROLE_ARN=$(aws iam get-role \
    --role-name "$EBS_CSI_ROLE_NAME" \
    --query 'Role.Arn' \
    --output text)

echo
echo "EBS CSI IAM Role:"
echo "$EBS_CSI_ROLE_ARN"

#############################################
# INSTALL / UPDATE EBS CSI ADD-ON
#############################################

info "Installing EBS CSI Driver"

POD_IDENTITY_ASSOCIATION=$(cat <<EOF
[
    {
        "serviceAccount": "ebs-csi-controller-sa",
        "roleArn": "$EBS_CSI_ROLE_ARN"
    }
]
EOF
)

if aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --addon-name "$EBS_CSI_ADDON" >/dev/null 2>&1
then

    echo "EBS CSI add-on already exists. Updating..."

    aws eks update-addon \
        --cluster-name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --addon-name "$EBS_CSI_ADDON" \
        --addon-version "$EBS_CSI_VERSION" \
        --pod-identity-associations "$POD_IDENTITY_ASSOCIATION" \
        --resolve-conflicts OVERWRITE

else

    echo "Creating EBS CSI add-on..."

    aws eks create-addon \
        --cluster-name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --addon-name "$EBS_CSI_ADDON" \
        --addon-version "$EBS_CSI_VERSION" \
        --pod-identity-associations "$POD_IDENTITY_ASSOCIATION" \
        --resolve-conflicts OVERWRITE
fi

#############################################
# WAIT FOR ADD-ON
#############################################

info "Waiting for EBS CSI Driver"

aws eks wait addon-active \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --addon-name "$EBS_CSI_ADDON"

echo "EBS CSI add-on is ACTIVE."

#############################################
# CREATE GP3 STORAGE CLASS
#############################################

info "Creating gp3 StorageClass"

cat > /tmp/gp3-storage-class.yaml <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS}
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Delete
parameters:
  type: gp3
  fsType: ext4
EOF

kubectl apply -f /tmp/gp3-storage-class.yaml

#############################################
# VERIFY
#############################################

info "Verifying EBS CSI installation"

kubectl get csidriver ebs.csi.aws.com

echo

kubectl get pods -n kube-system \
    -l app.kubernetes.io/name=aws-ebs-csi-driver

echo

kubectl get storageclass

#############################################
# DONE
#############################################

info "EKS STORAGE BOOTSTRAP COMPLETE"

echo "Cluster:        $CLUSTER_NAME"
echo "Kubernetes:     $K8S_VERSION"
echo "EBS CSI:        $EBS_CSI_VERSION"
echo "StorageClass:   $STORAGE_CLASS"
echo "IAM Role:       $EBS_CSI_ROLE_NAME"

echo
echo "You can now run:"
echo
echo "    ./deploy-eks.sh"
echo
