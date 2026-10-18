#!/usr/bin/env bash
# Demo: the API process in one pod is told to stop (what a liveness-probe
# restart does). Unlike a pod deletion, the pod stays in the Service until its
# readiness fails, so the app must keep serving while it drains.
source "$(dirname "$0")/../lib.sh"
D="$(dirname "$0")"
LOG="$(mktemp)"
POD="$(kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=api -o jsonpath='{.items[0].metadata.name}')"
show() { kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/component=api \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount' | sed 's/^/    /'; }

echo "## Before"; show
"$D/traffic.sh" start "$LOG"
sleep 5
echo; echo "## $(date +%H:%M:%S) SIGTERM to the API process (PID 1) in ${POD}: the container restarts, the pod stays"
kubectl -n "${NAMESPACE}" exec "${POD}" -- kill -TERM 1
sleep 8
echo; echo "## $(date +%H:%M:%S) While draining: readiness fails, requests are still answered"
show
kubectl -n "${NAMESPACE}" get endpointslices -l kubernetes.io/service-name="${RELEASE}-api" \
  -o jsonpath='{range .items[*].endpoints[*]}    {.targetRef.name} ready={.conditions.ready}{"\n"}{end}'
kubectl -n "${NAMESPACE}" wait --for=condition=Ready "pod/${POD}" --timeout=120s >/dev/null
sleep 5
"$D/traffic.sh" stop "$LOG"
echo; echo "## After: container restarted once and is Ready again"; show
echo; echo "## The pod's own log of the shutdown"
kubectl -n "${NAMESPACE}" logs "${POD}" --previous 2>/dev/null | grep -E "Shutting down|Drain period|Shutdown complete|Forced exit" | cut -c1-160 | sed 's/^/    /'
