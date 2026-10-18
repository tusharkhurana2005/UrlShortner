#!/usr/bin/env bash
# Demo: backups are only real if a restore works. Create data, back it up with
# the CronJob's own template, lose the data, restore it, check it is back.
source "$(dirname "$0")/../lib.sh"
B="${APP_URL}"
E="drill-$(date +%s)@example.com"
json() { python3 -c "import json,sys; print(eval('json.load(sys.stdin)' + sys.argv[1]))" "$1"; }

curl -s -o /dev/null -H 'Content-Type: application/json' -d "{\"name\":\"Drill\",\"email\":\"$E\",\"password\":\"drill-password-1\"}" "$B/api/user/signup"
T="$(curl -s -H 'Content-Type: application/json' -d "{\"email\":\"$E\",\"password\":\"drill-password-1\"}" "$B/api/user/login" | json "['token']")"
ID="$(curl -s -H 'Content-Type: application/json' -H "Authorization: Bearer $T" -d '{"Url":"https://kubernetes.io/docs/"}' "$B/api/url/create" | json "['Url']['shortUrl']")"
echo "## 1. Data exists: short link ${ID}"
curl -s -o /dev/null -w "  GET /r/${ID} -> %{http_code} %{redirect_url}\n" "$B/r/${ID}"

echo; echo "## 2. Backup (a Job created from the nightly CronJob)"
JOB="backup-drill-$(date +%s)"
kubectl -n "${NAMESPACE}" create job "${JOB}" --from=cronjob/"${RELEASE}-mongodb-backup" >/dev/null
kubectl -n "${NAMESPACE}" wait --for=condition=complete "job/${JOB}" --timeout=180s >/dev/null
kubectl -n "${NAMESPACE}" logs "job/${JOB}" | grep -E "done dumping|backup written" | sed 's/^/  /'

echo; echo "## 3. Disaster: the urls collection is dropped"
kubectl -n "${NAMESPACE}" exec "${RELEASE}-mongodb-0" -c mongodb -- sh -c \
  'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin Urls --eval "db.urls.drop()"' >/dev/null
curl -s -o /dev/null -w "  GET /r/${ID} -> %{http_code}  (link is gone)\n" "$B/r/${ID}"

echo; echo "## 4. Restore the newest archive (scripts/restore-backup.sh)"
"$(dirname "$0")/../restore-backup.sh" 2>&1 | grep -E "Restoring|restoring|document\(s\) restored|finished" | sed 's/^/  /'

echo; echo "## 5. Verify"
curl -s -o /dev/null -w "  GET /r/${ID} -> %{http_code} %{redirect_url}\n" "$B/r/${ID}"
kubectl -n "${NAMESPACE}" delete job "${JOB}" >/dev/null
