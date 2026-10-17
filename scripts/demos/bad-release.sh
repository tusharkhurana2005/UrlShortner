#!/usr/bin/env bash
# Demo: a bad release (misconfiguration that crashes the new pods) is stopped
# by readiness + maxUnavailable=0 and rolled back automatically by Helm.
source "$(dirname "$0")/../lib.sh"
D="$(dirname "$0")"
LOG="$(mktemp)"
GOOD="$(helm get values "${RELEASE}" -n "${NAMESPACE}" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["image"]["tag"])')"

echo "## Before: version ${GOOD} serving"; curl -s "${APP_URL}/api/version"; echo
"$D/traffic.sh" start "$LOG"

echo; echo "## Release ${GOOD} again with a bad setting (LOG_LEVEL=verbose is not a valid pino level, the process exits at startup)"
set +e
EXTRA_HELM_ARGS="--set api.logLevel=verbose" TIMEOUT=75s "$D/../deploy.sh" "${GOOD}" 2>&1 | grep -E "Error|rollback|failed|Deploying" 
rc=${PIPESTATUS[0]}
set -e
echo "deploy.sh exit code: ${rc} (non-zero = release rejected)"

echo; echo "## What Kubernetes saw: new pods crashed, old pods never stopped serving"
kubectl -n "${NAMESPACE}" get events --sort-by=.lastTimestamp 2>/dev/null | grep -E "urlshortener-api" | grep -E "BackOff|Unhealthy|Scaled" | tail -6
echo; echo "## Crash reason, from Loki (the failed pods are already gone, their logs are not)"
pgrep -f "port-forward svc/loki" >/dev/null || { kubectl -n "${OBS_NAMESPACE}" port-forward svc/loki 3100:3100 >/dev/null 2>&1 & sleep 2; }
curl -s --get http://localhost:3100/loki/api/v1/query_range \
  --data-urlencode "query={namespace=\"${NAMESPACE}\", component=\"api\"} |= \"level:verbose\"" \
  --data-urlencode 'limit=2' --data-urlencode "start=$(( $(date +%s) - 600 ))000000000" \
  | python3 -c 'import json,sys; [print("  ", s["stream"].get("pod"), "|", v[1].strip()) for s in json.load(sys.stdin)["data"]["result"] for v in s["values"][:1]]'

echo; echo "## Helm history: the failed revision and the automatic rollback"
helm history "${RELEASE}" -n "${NAMESPACE}" --max 3

"$D/traffic.sh" stop "$LOG"
echo; echo "## After"; curl -s "${APP_URL}/api/version"; echo
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=api
