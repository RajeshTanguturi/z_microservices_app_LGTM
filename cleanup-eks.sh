#!/usr/bin/env bash

set -euo pipefail

#############################################
# CONFIGURATION
#############################################

CLUSTER_NAME="microservices-eks"
AWS_REGION="us-east-1"

MONITORING_NAMESPACE="monitoring"
DEMO_NAMESPACE="demo"

STORAGE_CLASS="gp3"

#############################################
# HELPERS
#############################################

info() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

#############################################
# KUBECONFIG
#############################################

info "Updating kubeconfig"

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME"

#############################################
# WARNING
#############################################

echo
echo "WARNING:"
echo
echo "This will delete:"
echo
echo "  - demo namespace"
echo "  - monitoring namespace"
echo "  - Prometheus data"
echo "  - Loki data"
echo "  - Grafana data"
echo "  - monitoring PVCs"
echo "  - EBS volumes created by those PVCs"
echo
echo "The EKS cluster, node group, EBS CSI driver,"
echo "Pod Identity agent and IAM role will NOT be deleted."
echo

read -r -p "Continue? [y/N]: " CONFIRM

if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

#############################################
# DELETE DEMO
#############################################

info "Deleting demo namespace"

kubectl delete namespace "$DEMO_NAMESPACE" \
    --ignore-not-found

#############################################
# DELETE MONITORING
#############################################

info "Deleting monitoring namespace"

kubectl delete namespace "$MONITORING_NAMESPACE" \
    --ignore-not-found

#############################################
# WAIT FOR NAMESPACES
#############################################

info "Waiting for namespaces to disappear"

while kubectl get namespace "$DEMO_NAMESPACE" >/dev/null 2>&1; do
    echo "Waiting for demo namespace..."
    sleep 3
done

while kubectl get namespace "$MONITORING_NAMESPACE" >/dev/null 2>&1; do
    echo "Waiting for monitoring namespace..."
    sleep 3
done

#############################################
# DELETE STORAGE CLASS
#############################################

info "Deleting gp3 StorageClass"

kubectl delete storageclass "$STORAGE_CLASS" \
    --ignore-not-found

#############################################
# STATUS
#############################################

info "Remaining StorageClasses"

kubectl get storageclass

info "Cleanup complete"

echo
echo "The EKS infrastructure is still running."
echo
echo "To deploy everything again:"
echo
echo "    ./bootstrap-eks.sh"
echo "    ./deploy-eks.sh"
echo
