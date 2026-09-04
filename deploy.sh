#!/usr/bin/env bash
set -eo pipefail

echo "=================================================="
echo "  Deploying LGTM Stack & Microservices Demo on GKE"
echo "=================================================="

# Make sure paths are relative to the directory containing this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. Create target namespaces
echo "[1/8] Creating namespaces..."

kubectl create namespace monitoring \
  --dry-run=client \
  -o yaml | kubectl apply -f -

kubectl create namespace demo \
  --dry-run=client \
  -o yaml | kubectl apply -f -


# 2. Add Helm repositories
echo "[2/8] Adding Helm repositories..."

helm repo add grafana https://grafana.github.io/helm-charts --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts --force-update

helm repo update


# 3. Install Loki
echo "[3/8] Installing Loki..."

helm upgrade --install loki grafana/loki \
  --namespace monitoring \
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
  --set loki.auth_enabled=false


# 4. Install Tempo
echo "[4/8] Installing Tempo..."

helm upgrade --install tempo grafana/tempo \
  --namespace monitoring \
  --set tempo.receivers.otlp.protocols.grpc.endpoint=0.0.0.0:4317 \
  --set tempo.receivers.otlp.protocols.http.endpoint=0.0.0.0:4318


# 5. Install Prometheus
echo "[5/8] Installing Prometheus..."

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace monitoring \
  --set server.extraFlags[0]="enable-feature=remote-write-receiver" \
  --set alertmanager.enabled=false \
  --set kube-state-metrics.enabled=true \
  --set prometheus-node-exporter.enabled=true


# 6. Configure & Deploy Grafana
echo "[6/8] Configuring and Deploying Grafana..."

cat <<'EOF' > grafana-values.yaml
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
          httpHeaderName1: 'X-Scope-OrgID'
        secureJsonData:
          httpHeaderValue1: '1'

      - name: Tempo
        uid: Tempo
        type: tempo
        url: http://tempo.monitoring.svc.cluster.local:3200
        access: proxy
        editable: true
        jsonData:
          httpMethod: GET
          tracesToLogs:
            datasourceUid: 'Loki'
            tags:
              - 'k8s.pod.name'
              - 'service.name'
EOF

helm upgrade --install grafana grafana/grafana \
  --namespace monitoring \
  -f grafana-values.yaml

kubectl patch svc grafana \
  -n monitoring \
  -p '{"spec":{"type":"LoadBalancer"}}'


# 7. Configure & Deploy OpenTelemetry Collector
echo "[7/8] Configuring and Deploying OpenTelemetry Collector..."

cat <<'EOF' > otel-values.yaml
mode: daemonset

image:
  repository: "otel/opentelemetry-collector-contrib"

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
        "X-Scope-OrgID": "1"

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

helm upgrade --install otel-collector \
  open-telemetry/opentelemetry-collector \
  --namespace monitoring \
  -f otel-values.yaml


# 8. Deploy Microservices & Enable Telemetry
echo "[8/8] Deploying Google Microservices Demo..."

# Script is already inside the microservices-demo repository.
if [ ! -f "./release/kubernetes-manifests.yaml" ]; then
  echo "ERROR: ./release/kubernetes-manifests.yaml not found."
  echo "Run this script from inside the microservices-demo repository."
  exit 1
fi

kubectl apply \
  -f ./release/kubernetes-manifests.yaml \
  -n demo

echo "Waiting 10s for microservice deployments to register..."
sleep 10


# OpenTelemetry Collector endpoint
COLLECTOR_ADDR="otel-collector-opentelemetry-collector.monitoring.svc.cluster.local:4317"

echo "Configuring OpenTelemetry environment variables..."

for deploy in $(kubectl get deploy \
  -n demo \
  -o jsonpath='{.items[*].metadata.name}'); do

  echo "Configuring telemetry for deployment: $deploy"

  kubectl set env deployment/"$deploy" \
    -n demo \
    ENABLE_TRACING="1" \
    COLLECTOR_SERVICE_ADDR="$COLLECTOR_ADDR" \
    OTEL_EXPORTER_OTLP_ENDPOINT="http://$COLLECTOR_ADDR" \
    OTEL_EXPORTER_OTLP_PROTOCOL="grpc" \
    OTEL_SERVICE_NAME="$deploy"
done


echo "=================================================="
echo "  Deployment Complete! Fetching Access Details..."
echo "=================================================="

echo -n "Grafana Admin Password: "
kubectl get secret grafana \
  --namespace monitoring \
  -o jsonpath="{.data.admin-password}" \
  | base64 --decode
echo ""

echo ""
echo "Grafana Service:"
kubectl get svc grafana -n monitoring

echo ""
echo "Online Boutique Frontend Service:"
kubectl get svc frontend-external -n demo

echo ""
echo "=================================================="
echo "Check deployment status with:"
echo "  kubectl get pods -n monitoring"
echo "  kubectl get pods -n demo"
echo "=================================================="



