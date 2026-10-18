#!/usr/bin/env bash
# Roll back to a previous Helm revision (default: the one before the current)
# and prove the old version is serving again.
#   ./scripts/rollback.sh [REVISION]
source "$(dirname "$0")/lib.sh"
require helm kubectl

helm history "${RELEASE}" -n "${NAMESPACE}" --max 5
log "Rolling back ${RELEASE} to revision ${1:-previous}"
helm rollback "${RELEASE}" ${1:-} -n "${NAMESPACE}" --force-conflicts --wait=watcher --timeout 5m
TAG="$(helm get values "${RELEASE}" -n "${NAMESPACE}" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["image"]["tag"])')"
log "Now at tag ${TAG}; verifying"
"$(dirname "$0")/smoke-test.sh" "${APP_URL}" "${TAG}"
