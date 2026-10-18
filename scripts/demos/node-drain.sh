#!/usr/bin/env bash
# Demo: planned node maintenance. Draining a worker evicts its pods one at a
# time (PodDisruptionBudgets); replicas spread over both workers keep serving.
source "$(dirname "$0")/../lib.sh"
D="$(dirname "$0")"
NODE="${NODE:-${CLUSTER_NAME}-worker2}"
LOG="$(mktemp)"
show() { kubectl get pods -n "${NAMESPACE}" -l 'app.kubernetes.io/component in (api,web)' -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready' --no-headers | sed 's/^/    /'
         kubectl get pods -n platform -o custom-columns='POD:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready' --no-headers | sed 's/^/    /'; }

echo "## Before: replicas on both workers"; show
echo "  PDBs:"; kubectl get pdb -A --no-headers | grep -E "urlshortener|traefik" | awk '{printf "    %s/%s minAvailable=%s maxUnavailable=%s allowed=%s\n",$1,$2,$3,$4,$5}'
"$D/traffic.sh" start "$LOG"

echo; echo "## kubectl drain ${NODE}"
kubectl drain "${NODE}" --ignore-daemonsets --delete-emptydir-data --timeout=240s 2>&1 \
  | grep -E "evicting pod (urlshortener|platform)|drained|error|Cannot evict" | sed 's/^/    /'
sleep 10
echo; echo "## During maintenance: everything user-facing runs on the remaining worker"; show

echo; echo "## Maintenance done: kubectl uncordon ${NODE}"
kubectl uncordon "${NODE}"
"$D/traffic.sh" stop "$LOG"
echo
echo "Note: pods with node-local volumes (here Prometheus/Alertmanager/Tempo on"
echo "${NODE}) wait for the node to return: local-path volumes cannot move."
echo "MongoDB is never drained in this demo for the same reason (see docs)."
