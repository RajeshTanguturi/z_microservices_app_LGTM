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

error() {
    echo
    echo "ERROR: $1"
    exit 1
}

#############################################
# PROJECT DIRECTORY
#############################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

#############################################
# PREREQUISITES
#############################################

info "Checking prerequisites"

command -v aws >/dev/null 2>&1 || error "AWS CLI not installed"
command -v kubectl >/dev/null 2>&1 || error "kubectl not installed"
command -v helm >/dev/null 2>&1 || error "Helm not installed"

if [[ ! -f "./release/kubernetes-manifests.yaml" ]]; then
    error "./release/kubernetes-manifests.yaml not found"
fi

#############################################
# KUBECONFIG
#############################################

info "Updating kubeconfig"

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME"

#############################################
# VERIFY STORAGE
#############################################

info "Checking EBS CSI"

kubectl get csidriver ebs.csi.aws.com >/dev/null 2>&1 \
    || error "EBS CSI driver is not installed. Run ./bootstrap-eks.sh first."

kubectl get storageclass "$STORAGE_CLASS" >/dev/null 2>&1 \
    || error "StorageClass $STORAGE_CLASS does not exist. Run ./bootstrap-eks.sh first."

#############################################
# NAMESPACES
#############################################

info "Creating namespaces"

kubectl create namespace "$MONITORING_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create namespace "$DEMO_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

#############################################
# HELM REPOSITORIES
#############################################

info "Configuring Helm repositories"

helm repo add grafana \
    https://grafana.github.io/helm-charts \
    --force-update

helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts \
    --force-update

helm repo add open-telemetry \
    https://open-telemetry.github.io/opentelemetry-helm-charts \
    --force-update

helm repo update

#############################################
# LOKI
#############################################

info "Deploying Loki"

helm upgrade --install loki grafana/loki \
    --namespace "$MONITORING_NAMESPACE" \
    --set deploymentMode=SingleBinary \
    --set singleBinary.replicas=1 \
    --set read.replicas=0 \
    --set write.replicas=0 \
    --set backend.replicas=0 \
    --set loki.commonConfig.replication_factor=1 \
    --set loki.storage.type=filesystem \
    --set loki.storage.bucketNames.chunks=chunks \
    --set loki.storage.bucketNames.ruler=ruler \
    --set loki.storage.bucketNames.admin=admin \
    --set loki.useTestSchema=true \
    --set chunksCache.enabled=false \
    --set resultsCache.enabled=false \
    --set loki.auth_enabled=false \
    --set singleBinary.persistence.enabled=true \
    --set singleBinary.persistence.storageClassName="$STORAGE_CLASS" \
    --set singleBinary.persistence.size=10Gi

#############################################
# TEMPO
#############################################

info "Deploying Tempo"

helm upgrade --install tempo grafana/tempo \
    --namespace "$MONITORING_NAMESPACE" \
    --set tempo.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317 \
    --set tempo.receivers.otlp.protocols.http.endpoint=0.0.0.0:4318

#############################################
# PROMETHEUS
#############################################

info "Deploying Prometheus"

helm upgrade --install prometheus \
    prometheus-community/prometheus \
    --namespace "$MONITORING_NAMESPACE" \
    --set server.extraFlags[0]="enable-feature=remote-write-receiver" \
    --set server.persistentVolume.enabled=true \
    --set server.persistentVolume.storageClass="$STORAGE_CLASS" \
    --set server.persistentVolume.size=10Gi \
    --set alertmanager.enabled=false \
    --set kube-state-metrics.enabled=true \
    --set prometheus-node-exporter.enabled=true

#############################################
# GRAFANA VALUES
#############################################

info "Creating Grafana configuration"

cat > grafana-values.yaml <<'EOF'
datasources:
  datasources.yaml:
    apiVersion: 1

    datasources:

      - name: Prometheus
        uid: prometheus
        type: prometheus
        url: http://prometheus-server.monitoring.svc.cluster.local:80
        access: proxy
        isDefault: true
        editable: true

      - name: Loki
        uid: Loki
        type: loki
        url: http://loki.monitoring.svc.cluster.local:3100
        access: proxy
        editable: true

        jsonData:
          httpHeaderName1: X-Scope-OrgID

        secureJsonData:
          httpHeaderValue1: "1"

      - name: Tempo
        uid: Tempo
        type: tempo
        url: http://tempo.monitoring.svc.cluster.local:3200
        access: proxy
        editable: true

        jsonData:
          httpMethod: GET

          tracesToLogs:
            datasourceUid: Loki

            tags:
              - k8s.pod.name
              - service.name

persistence:
  enabled: true
  storageClassName: gp3
  size: 5Gi

service:
  type: LoadBalancer
EOF

#############################################
# GRAFANA
#############################################

info "Deploying Grafana"

helm upgrade --install grafana grafana/grafana \
    --namespace "$MONITORING_NAMESPACE" \
    -f grafana-values.yaml

#############################################
# OPENTELEMETRY
#############################################

info "Creating OpenTelemetry configuration"

cat > otel-values.yaml <<'EOF'
mode: daemonset

image:
  repository: otel/opentelemetry-collector-contrib

presets:

  logsCollection:
    enabled: true
    includeCollectorLogs: false

  kubernetesAttributes:
    enabled: true

service:
  enabled: true

ports:

  otlp:
    enabled: true
    containerPort: 4317
    servicePort: 4317
    protocol: TCP

  otlp-http:
    enabled: true
    containerPort: 4318
    servicePort: 4318
    protocol: TCP

config:

  receivers:

    otlp:

      protocols:

        grpc:
          endpoint: 0.0.0.0:4317

        http:
          endpoint: 0.0.0.0:4318

  exporters:

    otlp_grpc/tempo:
      endpoint: tempo.monitoring.svc.cluster.local:4317

      tls:
        insecure: true

    prometheusremotewrite:
      endpoint: http://prometheus-server.monitoring.svc.cluster.local:80/api/v1/write

      tls:
        insecure: true

    otlp_http/loki:
      endpoint: http://loki.monitoring.svc.cluster.local:3100/otlp

      headers:
        X-Scope-OrgID: "1"

  service:

    pipelines:

      traces:

        receivers:
          - otlp

        processors:
          - memory_limiter
          - k8s_attributes
          - batch

        exporters:
          - otlp_grpc/tempo

      metrics:

        receivers:
          - otlp

        processors:
          - memory_limiter
          - k8s_attributes
          - batch

        exporters:
          - prometheusremotewrite

      logs:

        receivers:
          - otlp
          - file_log

        processors:
          - memory_limiter
          - k8s_attributes
          - batch

        exporters:
          - otlp_http/loki
EOF

#############################################
# OPENTELEMETRY COLLECTOR
#############################################

info "Deploying OpenTelemetry Collector"

helm upgrade --install otel-collector \
    open-telemetry/opentelemetry-collector \
    --namespace "$MONITORING_NAMESPACE" \
    -f otel-values.yaml

#############################################
# DEMO APPLICATION
#############################################

info "Deploying Online Boutique microservices"

kubectl apply \
    -f ./release/kubernetes-manifests.yaml \
    -n "$DEMO_NAMESPACE"

#############################################
# WAIT
#############################################

info "Waiting for microservices"

sleep 10

#############################################
# CONFIGURE OTEL
#############################################

info "Configuring OpenTelemetry for microservices"

COLLECTOR_ADDR="otel-collector-opentelemetry-collector.${MONITORING_NAMESPACE}.svc.cluster.local:4317"

for deploy in $(kubectl get deployments \
    -n "$DEMO_NAMESPACE" \
    -o jsonpath='{.items[*].metadata.name}')
do

    echo "Configuring: $deploy"

    kubectl set env deployment/"$deploy" \
        -n "$DEMO_NAMESPACE" \
        ENABLE_TRACING="1" \
        COLLECTOR_SERVICE_ADDR="$COLLECTOR_ADDR" \
        OTEL_EXPORTER_OTLP_ENDPOINT="http://$COLLECTOR_ADDR" \
        OTEL_EXPORTER_OTLP_PROTOCOL="grpc" \
        OTEL_SERVICE_NAME="$deploy"

done

#############################################
# WAIT FOR ROLLOUTS
#############################################

info "Waiting for application rollouts"

for deploy in $(kubectl get deployments \
    -n "$DEMO_NAMESPACE" \
    -o jsonpath='{.items[*].metadata.name}')
do

    kubectl rollout status \
        deployment/"$deploy" \
        -n "$DEMO_NAMESPACE" \
        --timeout=180s

done

#############################################
# STATUS
#############################################

info "MONITORING PODS"

kubectl get pods -n "$MONITORING_NAMESPACE"

info "MONITORING PVCs"

kubectl get pvc -n "$MONITORING_NAMESPACE"

info "APPLICATION PODS"

kubectl get pods -n "$DEMO_NAMESPACE"

info "SERVICES"

kubectl get svc -n "$MONITORING_NAMESPACE"

echo
echo "============================================================"
echo "DEPLOYMENT COMPLETE"
echo "============================================================"

echo
echo "Grafana LoadBalancer:"
kubectl get svc grafana \
    -n "$MONITORING_NAMESPACE"

echo
echo "To get the Grafana address:"
echo
echo "kubectl get svc grafana -n monitoring"
echo
