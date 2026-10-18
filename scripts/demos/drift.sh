#!/usr/bin/env bash
# Demo: someone changes the cluster by hand. drift-check.sh finds it; a
# redeploy of the same version puts the cluster back to the reviewed state.
source "$(dirname "$0")/../lib.sh"
D="$(dirname "$0")"
TAG="$(helm get values "${RELEASE}" -n "${NAMESPACE}" -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["image"]["tag"])')"

echo "## 1. Cluster matches the release"
"$D/../drift-check.sh" 2>&1 | tail -1

echo; echo "## 2. Manual changes outside the pipeline ('quick fix' during debugging)"
echo "\$ kubectl -n ${NAMESPACE} scale deploy ${RELEASE}-web --replicas=1"
kubectl -n "${NAMESPACE}" scale deploy "${RELEASE}-web" --replicas=1
echo "\$ kubectl -n ${NAMESPACE} delete networkpolicy ${RELEASE}-api"
kubectl -n "${NAMESPACE}" delete networkpolicy "${RELEASE}-api"

echo; echo "## 3. Detection (the same check runs in CI after every deploy)"
set +e
"$D/../drift-check.sh" 2>&1 | grep -E "^diff|^[-+]  replicas|^\+  name: |DRIFT" | sed -E 's#/[^ ]*/(LIVE|MERGED)-[0-9]+/#\1/#g'
set -e

echo; echo "## 4. Remediation: redeploy the version that is already released (${TAG})"
"$D/../deploy.sh" "${TAG}" 2>&1 | grep -E "^STATUS|Phase|DESCRIPTION" | head -3
kubectl -n "${NAMESPACE}" get deploy "${RELEASE}-web" -o jsonpath='  web replicas: {.spec.replicas}{"\n"}'
kubectl -n "${NAMESPACE}" get networkpolicy "${RELEASE}-api" -o name | sed 's/^/  restored: /'

echo; echo "## 5. Verify"
"$D/../drift-check.sh" 2>&1 | tail -1
