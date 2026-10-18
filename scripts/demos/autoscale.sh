#!/usr/bin/env bash
# Demo: load drives API CPU above the HPA target (70% of the 50m request);
# the HPA adds replicas, then scales back down after the stabilization window.
source "$(dirname "$0")/../lib.sh"
require ab
DURATION="${DURATION:-150}"
hpa() { kubectl -n "${NAMESPACE}" get hpa "${RELEASE}-api" --no-headers | awk -v t="$(date +%H:%M:%S)" '{print "  " t "  " $3 " " $4 "  replicas=" $7}'; }

echo "## Before"; hpa
echo; echo "## ${DURATION}s of load: ApacheBench, 25 concurrent clients on GET /api/version through the ingress"
# 127.0.0.1, not localhost: ab tries IPv6 ::1 first and kind only listens on IPv4.
ab -q -k -t "${DURATION}" -n 100000000 -c 25 "${APP_URL/localhost/127.0.0.1}/api/version" > /tmp/ab-$$.txt 2>&1 &
AB=$!
for _ in $(seq 1 $(( DURATION / 15 ))); do sleep 15; hpa; done
wait "$AB" || true
grep -E "Complete requests|Failed requests|Non-2xx|Requests per second|Time per request.*mean\)|99%" /tmp/ab-$$.txt | sed 's/^/  /' || cat /tmp/ab-$$.txt
echo; echo "## After the load stops: HPA scales back down after its 120s stabilization window"
until [[ "$(kubectl -n "${NAMESPACE}" get hpa "${RELEASE}-api" -o jsonpath='{.status.currentReplicas}')" == "$(kubectl -n "${NAMESPACE}" get hpa "${RELEASE}-api" -o jsonpath='{.spec.minReplicas}')" ]]; do sleep 15; hpa; done
echo; echo "## Scaling events"
kubectl -n "${NAMESPACE}" get events --field-selector involvedObject.name="${RELEASE}-api",reason=SuccessfulRescale --sort-by=.lastTimestamp | tail -4 | sed 's/^/  /'
