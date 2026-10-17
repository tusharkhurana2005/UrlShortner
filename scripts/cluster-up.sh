#!/usr/bin/env bash
# Creates the local kind cluster (idempotent).
source "$(dirname "$0")/lib.sh"
require kind kubectl docker

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  log "kind cluster '${CLUSTER_NAME}' already exists"
else
  log "Creating kind cluster '${CLUSTER_NAME}'"
  kind create cluster --name "${CLUSTER_NAME}" --config "${ROOT_DIR}/deploy/kind/cluster.yaml" --wait 120s
fi
kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s
