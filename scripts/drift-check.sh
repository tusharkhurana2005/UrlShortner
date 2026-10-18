#!/usr/bin/env bash
# Detects drift: compares what Helm last deployed (the reviewed source of
# truth) with what is actually running. Any `kubectl edit/scale/set image`
# done by hand shows up here. Exit code 1 = drift found.
source "$(dirname "$0")/lib.sh"
require helm kubectl

log "Comparing release '${RELEASE}' manifest with live objects in '${NAMESPACE}'"
set +e
helm get manifest "${RELEASE}" -n "${NAMESPACE}" | kubectl diff -n "${NAMESPACE}" -f -
rc=$?
set -e
case $rc in
  0) log "No drift: cluster matches the deployed release" ;;
  1) printf '\033[1;33mDRIFT DETECTED\033[0m: fix it by redeploying (scripts/deploy.sh) or by committing the change.\n'; exit 1 ;;
  *) fail "kubectl diff failed (exit ${rc})" ;;
esac
