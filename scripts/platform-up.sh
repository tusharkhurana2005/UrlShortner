#!/usr/bin/env bash
# Installs the shared platform: ingress, metrics-server and the observability
# stack. Chart versions are pinned so every install is the same.
#   ./scripts/platform-up.sh                 everything (local cluster)
#   ./scripts/platform-up.sh --ingress-only  just Traefik (CI)
source "$(dirname "$0")/lib.sh"
require helm kubectl

PLATFORM_DIR="${ROOT_DIR}/deploy/platform"

helm repo add traefik https://traefik.github.io/charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo add grafana-community https://grafana-community.github.io/helm-charts >/dev/null
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ >/dev/null
helm repo update >/dev/null

kubectl create namespace platform --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace "${OBS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# node-exporter needs host access, so this namespace cannot use the restricted profile.
kubectl label namespace "${OBS_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null

install() {
  local name="$1" chart="$2" version="$3" ns="$4" values="$5"; shift 5
  log "helm upgrade --install ${name} (${chart} ${version})"
  helm upgrade --install "${name}" "${chart}" --version "${version}" \
    --namespace "${ns}" --values "${PLATFORM_DIR}/${values}" --wait --timeout 10m "$@"
}

if [[ "${1:-}" == "--ingress-only" ]]; then
  # CI: only the ingress controller, without monitoring CRDs or tracing.
  install traefik traefik/traefik 42.0.0 platform traefik.yaml \
    --set metrics.prometheus.serviceMonitor.enabled=false \
    --set tracing.otlp.enabled=false
  exit 0
fi

install kube-prometheus-stack prometheus-community/kube-prometheus-stack 92.10.1 "${OBS_NAMESPACE}" kube-prometheus-stack.yaml
install loki     grafana-community/loki   18.17.0 "${OBS_NAMESPACE}" loki.yaml
install tempo    grafana-community/tempo  3.2.0   "${OBS_NAMESPACE}" tempo.yaml
install alloy    grafana/alloy            1.13.1  "${OBS_NAMESPACE}" alloy.yaml
install metrics-server metrics-server/metrics-server 3.14.0 kube-system metrics-server.yaml
install traefik  traefik/traefik          42.0.0  platform traefik.yaml

log "Platform ready"
