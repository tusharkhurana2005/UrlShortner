#!/usr/bin/env bash
# Demo: the database goes away. Shows the symptom users see, the evidence in
# metrics/alerts/logs, the recovery action, and how recovery is verified.
source "$(dirname "$0")/../lib.sh"
D="$(dirname "$0")"
LOG="$(mktemp)"
OUTAGE_SECONDS="${OUTAGE_SECONDS:-210}"

pgrep -f "port-forward svc/kube-prometheus-stack-prometheus" >/dev/null || { kubectl -n "${OBS_NAMESPACE}" port-forward svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 & sleep 2; }
prom() { curl -s --get http://localhost:9090/api/v1/query --data-urlencode "query=$1" | python3 -c '
import json,sys
r=json.load(sys.stdin)["data"]["result"]
print("    (none)") if not r else [print("   ", {k:v for k,v in x["metric"].items() if k in ("alertname","alertstate","severity","pod","code")}, x["value"][1]) for x in r]'; }
alerts() { prom 'ALERTS{alertname=~"UrlShortener.*"}'; }
ts() { date +%H:%M:%S; }

echo "## $(ts) Baseline"
echo "  readiness of API pods:"; kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=api -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' | sed 's/^/    /'
echo "  firing app alerts:"; alerts
"$D/traffic.sh" start "$LOG"

echo; echo "## $(ts) FAULT: MongoDB stops (StatefulSet scaled to 0, like a crashed DB pod/node)"
kubectl -n "${NAMESPACE}" scale statefulset "${RELEASE}-mongodb" --replicas=0
sleep 40

echo; echo "## $(ts) SYMPTOM (what a user gets)"
printf '  GET /api/version -> '; curl -s -o /dev/null -w '%{http_code}\n' "${APP_URL}/api/version"
printf '  GET /r/anything  -> '; curl -s -o /dev/null -w '%{http_code}\n' "${APP_URL}/r/anything"
echo "  response body: $(curl -s "${APP_URL}/api/version" | head -c 80)"

echo; echo "## $(ts) EVIDENCE"
echo "  API pods: Running but NOT Ready (readiness = Mongo connected); RESTARTS unchanged (liveness ignores Mongo):"
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=api -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' | sed 's/^/    /'
echo "  readiness endpoint from inside a pod:"
kubectl -n "${NAMESPACE}" exec deploy/"${RELEASE}-api" -- wget -qO- http://127.0.0.1:8000/readyz 2>&1 | sed 's/^/    /' || true
echo "  service endpoints (empty = Traefik has nowhere to send /api):"
kubectl -n "${NAMESPACE}" get endpointslices -l kubernetes.io/service-name="${RELEASE}-api" -o jsonpath='{range .items[*].endpoints[*]}    {.targetRef.name} ready={.conditions.ready}{"\n"}{end}'
echo "  metric urlshortener_mongo_up per pod:"; prom "urlshortener_mongo_up{namespace=\"${NAMESPACE}\"}"
echo "  API log lines:"; kubectl -n "${NAMESPACE}" logs deploy/"${RELEASE}-api" --since=60s | grep -iE "mongo" | tail -2 | cut -c1-170 | sed 's/^/    /'

remaining=$(( OUTAGE_SECONDS - 40 ))
echo; echo "## $(ts) waiting ${remaining}s so the alerts pass their 'for' duration..."
sleep "${remaining}"
echo "  firing/pending app alerts:"; alerts
echo "  edge (Traefik) 5xx ratio over 5m: $(curl -s --get http://localhost:9090/api/v1/query --data-urlencode 'query=urlshortener:error_ratio:rate5m' | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "n/a")')"

echo; echo "## $(ts) ACTION (runbook: MongoDB unavailable -> restore the database)"
kubectl -n "${NAMESPACE}" scale statefulset "${RELEASE}-mongodb" --replicas=1
start=$(date +%s)
kubectl -n "${NAMESPACE}" rollout status statefulset "${RELEASE}-mongodb" --timeout=180s
until [[ "$(curl -s -o /dev/null -w '%{http_code}' "${APP_URL}/api/version")" == 200 ]]; do sleep 1; done
echo "  users served again $(( $(date +%s) - start ))s after the database was started (no API restart needed)"

echo; echo "## $(ts) VERIFY"
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=api -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' | sed 's/^/    /'
"$D/../smoke-test.sh" "${APP_URL}" | sed 's/^/  /'
if [[ -n "${KEEP_LINK:-}" ]]; then
  printf '  data written before the outage survived (PVC): GET /r/%s -> ' "${KEEP_LINK}"
  curl -s -o /dev/null -w '%{http_code} %{redirect_url}\n' "${APP_URL}/r/${KEEP_LINK}"
fi
sleep 30
"$D/traffic.sh" stop "$LOG"
echo "  alerts 30s after recovery (resolve once their windows clear):"; alerts
