#!/usr/bin/env bash
# Proves the runtime security controls are enforced, not just declared.
source "$(dirname "$0")/lib.sh"
require kubectl

MONGO="${RELEASE}-mongodb-0.${RELEASE}-mongodb.${NAMESPACE}.svc.cluster.local"
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

echo "1. Pod Security Admission on namespace ${NAMESPACE}"
kubectl get ns "${NAMESPACE}" -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep pod-security | sed 's/^/     /'
if kubectl -n "${NAMESPACE}" run psa-probe --image=busybox:1.37 --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"p","image":"busybox:1.37","securityContext":{"privileged":true}}]}}' \
     --dry-run=server -o name >/dev/null 2>&1; then
  bad "a privileged pod was admitted"
else
  ok "privileged pod rejected by the API server"
fi

echo "2. Workload hardening (every running container)"
kubectl -n "${NAMESPACE}" get pods -l app.kubernetes.io/instance="${RELEASE}" -o json | python3 -c '
import json,sys
for p in json.load(sys.stdin)["items"]:
    if p["status"]["phase"] != "Running": continue
    ps = p["spec"].get("securityContext", {})
    for c in p["spec"]["containers"]:
        sc = c.get("securityContext", {})
        checks = {
            "nonRoot": ps.get("runAsNonRoot") is True,
            "uid": ps.get("runAsUser"),
            "readOnlyFS": sc.get("readOnlyRootFilesystem") is True,
            "noPrivEsc": sc.get("allowPrivilegeEscalation") is False,
            "capsDropped": sc.get("capabilities", {}).get("drop") == ["ALL"],
            "seccomp": ps.get("seccompProfile", {}).get("type"),
            "saToken": p["spec"].get("automountServiceAccountToken"),
        }
        name, cname = p["metadata"]["name"][:34], c["name"]
        print(f"     {name:34s} {cname:9s} {checks}")
'
uid="$(kubectl -n "${NAMESPACE}" exec deploy/${RELEASE}-api -- id -u)"
[[ "$uid" != 0 ]] && ok "API process runs as uid ${uid}" || bad "API runs as root"
if kubectl -n "${NAMESPACE}" exec deploy/${RELEASE}-api -- sh -c 'touch /app/x' 2>/dev/null; then bad "API can write its code"; else ok "API cannot modify its own filesystem"; fi
if kubectl -n "${NAMESPACE}" exec deploy/${RELEASE}-api -- ls /var/run/secrets/kubernetes.io/serviceaccount >/dev/null 2>&1; then bad "service account token mounted"; else ok "no Kubernetes API token in the API pod"; fi

echo "3. NetworkPolicy enforcement"
probe() { # $1=description $2=expect(allow|deny) $3...=command
  local desc="$1" expect="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=allow; else got=deny; fi
  [[ "$got" == "$expect" ]] && ok "${desc}: ${got}" || bad "${desc}: ${got} (expected ${expect})"
}
probe "api -> mongodb:27017" allow kubectl -n "${NAMESPACE}" exec deploy/${RELEASE}-api -- nc -z -w 3 "${MONGO}" 27017
probe "web -> mongodb:27017" deny  kubectl -n "${NAMESPACE}" exec deploy/${RELEASE}-web -- nc -z -w 3 "${MONGO}" 27017
probe "web -> api:8000 (web is static, needs nothing)" deny kubectl -n "${NAMESPACE}" exec deploy/${RELEASE}-web -- nc -z -w 3 "${RELEASE}-api" 8000
probe "api -> internet (egress)" deny kubectl -n "${NAMESPACE}" exec deploy/${RELEASE}-api -- nc -z -w 3 1.1.1.1 443
probe "pod in 'default' namespace -> mongodb" deny kubectl run np-probe-$$ --rm -i --quiet --restart=Never --image=busybox:1.37 \
  --image-pull-policy=IfNotPresent -- nc -z -w 3 "${MONGO}" 27017

echo "4. Exposure: only the ingress is reachable from the host"
code="$(curl -s -o /dev/null -w '%{http_code}' "${APP_URL}/metrics")"
body="$(curl -s "${APP_URL}/metrics" | head -c 15)"
[[ "$body" != "# HELP"* ]] && ok "/metrics not exposed through the ingress (got ${code} from the web app)" || bad "/metrics exposed"
kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type!="ClusterIP")]}{.metadata.namespace}/{.metadata.name} {.spec.type}{"\n"}{end}' | sed 's/^/     non-ClusterIP service: /'

echo "5. Secrets"
kubectl -n "${NAMESPACE}" get secrets -o custom-columns='NAME:.metadata.name,KEYS:.data' --no-headers | awk '{print "     " $1}' | grep -v sh.helm
if git -C "${ROOT_DIR}" grep -nIE '(password|secret)[[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9]{12,}' -- ':!**/node_modules/**' ':!**/package-lock.json' >/dev/null; then
  bad "possible hard-coded credential in git"
else
  ok "no hard-coded credentials in tracked files (gitleaks runs in CI over full history)"
fi

exit "${FAILED}"
