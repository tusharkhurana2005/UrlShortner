#!/usr/bin/env bash
# End-to-end user journey through the public entry point, exactly as a browser
# would do it: version -> signup -> login -> shorten -> list -> follow the
# short link (302) -> delete. Exits non-zero on the first failure.
#   ./scripts/smoke-test.sh [BASE_URL] [EXPECTED_VERSION]
set -euo pipefail
BASE_URL="${1:-${APP_URL:-http://localhost:8080}}"
EXPECTED_VERSION="${2:-}"
EMAIL="smoke-$(date +%s)-${RANDOM}@example.com"
PASSWORD="smoke-pass-${RANDOM}${RANDOM}"
TARGET="https://example.com/smoke/${RANDOM}"

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
die()  { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval('d' + sys.argv[1]))" "$1"; }

echo "Smoke test against ${BASE_URL}"

version_json="$(curl -fsS "${BASE_URL}/api/version")" || die "GET /api/version"
version="$(echo "${version_json}" | json "['version']")"
commit="$(echo "${version_json}" | json "['commit']")"
pass "API version ${version} (commit ${commit})"
if [[ -n "${EXPECTED_VERSION}" && "${version}" != "${EXPECTED_VERSION}" ]]; then
  die "expected version ${EXPECTED_VERSION} but ${version} is serving"
fi

curl -fsS "${BASE_URL}/" | grep -q '<div id="root">' || die "GET / (web frontend)"
pass "web frontend served"

code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
  -d "{\"name\":\"Smoke\",\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}" "${BASE_URL}/api/user/signup")"
[[ "${code}" == 201 ]] || die "signup returned ${code}"
pass "signup (201)"

token="$(curl -fsS -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}" "${BASE_URL}/api/user/login" | json "['token']")" || die "login"
pass "login returned a token"

short="$(curl -fsS -H 'Content-Type: application/json' -H "Authorization: Bearer ${token}" \
  -d "{\"Url\":\"${TARGET}\"}" "${BASE_URL}/api/url/create" | json "['Url']['shortUrl']")" || die "create short url"
pass "created short url ${short}"

curl -fsS -H "Authorization: Bearer ${token}" "${BASE_URL}/api/url/allUrls" | grep -q "\"${short}\"" || die "short url missing from list"
pass "short url listed for its owner"

location="$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' "${BASE_URL}/r/${short}")"
[[ "${location}" == "302 ${TARGET}" ]] || die "redirect returned '${location}'"
pass "GET /r/${short} -> 302 ${TARGET}"

code="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${token}" "${BASE_URL}/api/url/delete/${short}")"
[[ "${code}" == 200 ]] || die "delete returned ${code}"
code="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/r/${short}")"
[[ "${code}" == 404 ]] || die "deleted link returned ${code}, expected 404"
pass "deleted; link now 404"

echo "Smoke test passed"
