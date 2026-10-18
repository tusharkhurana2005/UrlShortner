#!/usr/bin/env bash
# Regenerates docs/evidence/ from the live cluster for the current commit:
# build -> deploy -> verify -> every failure experiment -> quality gates.
# Takes ~25 minutes. Each file starts with the commit and time it was produced.
#   ./scripts/collect-evidence.sh            all steps
#   ./scripts/collect-evidence.sh 06 08      only those steps (after a full run)
source "$(dirname "$0")/lib.sh"
E="${ROOT_DIR}/docs/evidence"
mkdir -p "$E"
S="$(dirname "$0")"
strip() { sed 's/\x1b\[[0-9;]*m//g'; }
header() { echo "# $1"; echo "# commit $(git -C "${ROOT_DIR}" rev-parse HEAD), generated $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo; }

run() { # $1=file $2=title, rest=command
  local f="$1" t="$2"; shift 2
  log "evidence: $f"
  { header "$t"; "$@"; } 2>&1 | strip > "$E/$f"
}

deploy_and_smoke() {
  "$S/build-images.sh" >/dev/null 2>&1
  TAG="$(cat "${ROOT_DIR}/.last-built-tag")"
  echo "\$ make build && make deploy   (image tag ${TAG})"
  "$S/deploy.sh" "$TAG" | grep -vE "^\s*$"
  echo; echo "\$ make smoke"; "$S/smoke-test.sh" "${APP_URL}" "$TAG"
  echo; echo "\$ curl -s ${APP_URL}/api/version"; curl -s "${APP_URL}/api/version"; echo
  echo "\$ curl -s ${APP_URL}/version.json   (web build)"; curl -s "${APP_URL}/version.json"
  echo; echo "\$ docker image inspect urlshortener-api:${TAG} --format '{{json .Config.Labels}}'"
  docker image inspect "urlshortener-api:${TAG}" --format '{{json .Config.Labels}}'
  echo; echo "\$ kubectl get deploy,sts -l app.kubernetes.io/instance=${RELEASE} (version label = image tag)"
  kubectl -n "${NAMESPACE}" get deploy,sts -l app.kubernetes.io/instance="${RELEASE}" -L app.kubernetes.io/version
}

quality_gates() {
  echo "## API: lint + tests + audit"
  (cd "${ROOT_DIR}/server" && npm ci --ignore-scripts --silent && npx eslint . && echo "eslint: clean" && npx jest --runInBand --coverage 2>&1 | grep -E "Tests:|All files" && npm audit --omit=dev --audit-level=high | tail -1)
  echo; echo "## Web: tests + build + audit"
  (cd "${ROOT_DIR}/client" && npm ci --ignore-scripts --silent && CI=true npx react-scripts test --watchAll=false 2>&1 | grep -E "Tests:" && CI=true npm run build --silent 2>&1 | grep -E "Compiled|Failed" ; npm audit --omit=dev --audit-level=high | tail -2)
  echo; echo "## Helm lint (every environment) + kubeconform"
  for env in "${CHART_DIR}"/environments/*.yaml; do helm lint "${CHART_DIR}" --strict -f "$env" --set image.tag=x | tail -1 | sed "s#^#$(basename "$env"): #"; done
  for env in "${CHART_DIR}"/environments/*.yaml; do
    printf '%s: ' "$(basename "$env")"
    helm template urlshortener "${CHART_DIR}" -f "$env" --set image.tag=x | kubeconform -strict -summary -kubernetes-version 1.34.0 \
      -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
  done
  echo; echo "## hadolint"; hadolint "${ROOT_DIR}/server/Dockerfile" "${ROOT_DIR}/client/Dockerfile" && echo "hadolint: clean"
  TAG="$(cat "${ROOT_DIR}/.last-built-tag")"
  echo; echo "## Trivy image scan (fixable HIGH/CRITICAL fails the build)"
  for c in api web; do
    trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 --format json "urlshortener-$c:$TAG" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); n=sum(len(r.get('Vulnerabilities') or []) for r in d.get('Results',[])); print(f'urlshortener-$c:$TAG  fixable HIGH/CRITICAL: {n}')"
  done
  echo; echo "## Trivy config scan (chart, Dockerfiles, platform values)"
  trivy config --quiet --severity HIGH,CRITICAL --exit-code 1 --skip-dirs client/node_modules,server/node_modules "${ROOT_DIR}" >/dev/null && echo "trivy config: 0 HIGH/CRITICAL misconfigurations"
  echo; echo "## gitleaks (full git history)"; gitleaks git "${ROOT_DIR}" --redact --no-banner 2>&1 | tail -2
}

STEPS="${*:-01 02 03 04 05 06 07 08 09 10}"
want() { [[ " ${STEPS} " == *" $1 "* ]]; }

want 01 && run 01-deploy-and-smoke-test.txt "Build, deploy and end-to-end smoke test" deploy_and_smoke
want 02 && run 02-security-verification.txt "Runtime security controls (scripts/verify-security.sh)" "$S/verify-security.sh"
want 03 && run 03-drift-detection-and-remediation.txt "Drift detection and remediation (scripts/demos/drift.sh)" "$S/demos/drift.sh"
if want 04; then
  for _ in $(seq 1 10); do "$S/smoke-test.sh" >/dev/null 2>&1 || true; done
  run 04-observability.txt "Metrics, logs, traces and their correlation (scripts/verify-observability.sh)" "$S/verify-observability.sh"
fi
want 05 && run 05-bad-release-auto-rollback.txt "Bad release is rolled back automatically (scripts/demos/bad-release.sh)" "$S/demos/bad-release.sh"
want 06 && run 06-mongodb-outage-and-recovery.txt "MongoDB outage: symptom, evidence, action, verification (scripts/demos/mongodb-outage.sh)" env OUTAGE_SECONDS=240 "$S/demos/mongodb-outage.sh"
want 07 && run 07-node-drain.txt "Node maintenance with PDBs and topology spread (scripts/demos/node-drain.sh)" "$S/demos/node-drain.sh"
want 08 && run 08-autoscaling.txt "Horizontal Pod Autoscaler under load (scripts/demos/autoscale.sh)" "$S/demos/autoscale.sh"
want 09 && run 09-backup-restore-drill.txt "Backup and restore drill (scripts/demos/backup-restore.sh)" "$S/demos/backup-restore.sh"
want 10 && run 10-quality-gates.txt "Local run of the CI quality gates" quality_gates
log "Evidence written to docs/evidence/"
