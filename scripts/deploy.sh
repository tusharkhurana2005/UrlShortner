#!/usr/bin/env bash
# Deploys one immutable image tag with Helm and verifies it.
#   ./scripts/deploy.sh [TAG]        (default: last tag built by build-images.sh)
#   ENVIRONMENT=ci ./scripts/deploy.sh <sha>
#
# --rollback-on-failure: if any new pod fails its probes within the timeout,
# Helm restores the previous release automatically, so a broken build never
# replaces a working one.
# --force-conflicts: Helm 4 uses server-side apply. If someone changed a field
# by hand (kubectl scale/edit), that manager now owns the field and the apply
# would be refused. The reviewed release is the source of truth, so it wins.
source "$(dirname "$0")/lib.sh"
require helm kubectl

ENVIRONMENT="${ENVIRONMENT:-local}"
TAG="${1:-${TAG:-$(cat "${ROOT_DIR}/.last-built-tag" 2>/dev/null || true)}}"
[[ -n "${TAG}" ]] || fail "no image tag given and no .last-built-tag found; run scripts/build-images.sh first"
TIMEOUT="${TIMEOUT:-5m}"

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Pod Security Admission: reject any pod in the app namespace that is not
# non-root, privilege-escalation-free, capability-less and seccomp-confined.
kubectl label namespace "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted --overwrite >/dev/null

for s in urlshortener-mongo urlshortener-api; do
  kubectl -n "${NAMESPACE}" get secret "$s" >/dev/null 2>&1 || fail "secret ${s} missing; run scripts/create-secrets.sh"
done

COMMIT_MSG="$(git -C "${ROOT_DIR}" log -1 --format=%s 2>/dev/null | cut -c1-60 || echo unknown)"
# The chart/config may come from a newer commit than the images; record both.
CHART_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short=7 HEAD 2>/dev/null || echo unknown)"
[[ -n "$(git -C "${ROOT_DIR}" status --porcelain -- deploy 2>/dev/null)" ]] && CHART_COMMIT="${CHART_COMMIT}-dirty"

# Package the chart with appVersion = image tag, so `helm list/history` show
# exactly which build each revision deployed.
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR:?}"' EXIT
helm package "${CHART_DIR}" --app-version "${TAG}" --destination "${PKG_DIR}" >/dev/null
CHART_PKG="$(ls "${PKG_DIR}"/*.tgz)"

log "Deploying ${RELEASE} tag=${TAG} env=${ENVIRONMENT} ns=${NAMESPACE}"
helm upgrade --install "${RELEASE}" "${CHART_PKG}" \
  --namespace "${NAMESPACE}" \
  --values "${CHART_DIR}/environments/${ENVIRONMENT}.yaml" \
  --set image.tag="${TAG}" \
  ${EXTRA_HELM_ARGS:-} \
  --rollback-on-failure \
  --force-conflicts \
  --wait=watcher \
  --timeout "${TIMEOUT}" \
  --history-max 10 \
  --description "image=${TAG} chart=${CHART_COMMIT} env=${ENVIRONMENT} by=${USER:-ci}: ${COMMIT_MSG}"

log "Rollout complete; running in-cluster smoke test (helm test)"
helm test "${RELEASE}" --namespace "${NAMESPACE}" --timeout 2m

helm history "${RELEASE}" --namespace "${NAMESPACE}" --max 5
kubectl -n "${NAMESPACE}" get deploy,statefulset -l app.kubernetes.io/instance="${RELEASE}" \
  -o custom-columns='KIND:.kind,NAME:.metadata.name,READY:.status.readyReplicas,VERSION:.metadata.labels.app\.kubernetes\.io/version'
