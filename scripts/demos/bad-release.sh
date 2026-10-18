#!/usr/bin/env bash
# Demo: a bad release (misconfiguration that crashes the new pods) is stopped
# by readiness + maxUnavailable=0 and rolled back automatically by Helm.
source "$(dirname "$0")/../lib.sh"
D="$(dirname "$0")"
LOG="$(mktemp)"
GOOD="$(helm get values "${RELEASE}" -n "${NAMESPACE}" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["image"]["tag"])')"

echo "## Before: version ${GOOD} serving"; curl -s "${APP_URL}/api/version"; echo
"$D/traffic.sh" start "$LOG"

# The ReplicaSet currently serving (its pods carry this pod-template-hash).
GOOD_HASH="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=api \
  -o jsonpath='{.items[0].metadata.labels.pod-template-hash}')"

echo; echo "## Release ${GOOD} again with a bad setting (LOG_LEVEL=verbose is not a valid pino level, the process exits at startup)"
OUT="$(mktemp)"
EXTRA_HELM_ARGS="--set api.logLevel=verbose" TIMEOUT=75s "$D/../deploy.sh" "${GOOD}" > "$OUT" 2>&1 &
DPID=$!

# Mid-rollout, an old pod restarts (eviction, OOM, node loss...). Its
# replacement must start with the OLD config, not the bad release's config.
sleep 25
VICTIM="$(kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/component=api,pod-template-hash=${GOOD_HASH}" -o jsonpath='{.items[0].metadata.name}')"
echo; echo "## While the bad release is rolling out: delete old pod ${VICTIM}"
kubectl -n "${NAMESPACE}" delete pod "${VICTIM}" --wait=false
sleep 3
kubectl -n "${NAMESPACE}" wait --for=condition=Ready pod -l "app.kubernetes.io/component=api,pod-template-hash=${GOOD_HASH}" --timeout=90s >/dev/null
echo "  pods of the serving ReplicaSet (${GOOD_HASH}) during the bad release:"
kubectl -n "${NAMESPACE}" get pods -l "app.kubernetes.io/component=api" \
  -o custom-columns='POD:.metadata.name,RS-HASH:.metadata.labels.pod-template-hash,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,LOG_LEVEL:.spec.containers[0].env[2].value' | sed 's/^/    /'

set +e
wait "$DPID"; rc=$?
set -e
grep -E "Error|rollback|failed|Deploying" "$OUT"
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
