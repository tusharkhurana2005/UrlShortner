#!/usr/bin/env bash
# Generates credentials directly inside the cluster. Nothing is written to disk
# or to git; existing secrets are left untouched so re-running is safe.
#
# Production alternative: External Secrets Operator / Sealed Secrets backed by a
# real secret store, with rotation.
source "$(dirname "$0")/lib.sh"
require kubectl openssl

rand() { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

ensure_secret() {
  local ns="$1" name="$2"; shift 2
  if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
    log "secret ${ns}/${name} exists, keeping it"
  else
    log "creating secret ${ns}/${name}"
    kubectl -n "$ns" create secret generic "$name" "$@" >/dev/null
  fi
}

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace "${OBS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# Credentials only; hostnames live in the Helm chart. Passwords are
# alphanumeric so they are safe inside a mongodb:// URI without escaping.
ensure_secret "${NAMESPACE}" urlshortener-mongo \
  --from-literal=root-username=root \
  --from-literal=root-password="$(rand 32)" \
  --from-literal=app-username=urlshortener \
  --from-literal=app-password="$(rand 32)" \
  --from-literal=exporter-username=exporter \
  --from-literal=exporter-password="$(rand 32)"

ensure_secret "${NAMESPACE}" urlshortener-api \
  --from-literal=jwt-secret="$(rand 64)"

ensure_secret "${OBS_NAMESPACE}" grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(rand 24)"
