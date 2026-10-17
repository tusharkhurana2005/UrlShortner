#!/usr/bin/env bash
# Background "user": calls the API through the ingress ~5 times a second and
# records every status code, so a demo can show exactly what users saw.
#   traffic.sh start <logfile>   |   traffic.sh stop <logfile>
set -euo pipefail
APP_URL="${APP_URL:-http://localhost:8080}"
cmd="$1"; logf="$2"

case "$cmd" in
  start)
    : > "$logf"
    (
      while true; do
        code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "${APP_URL}/api/version" || echo 000)
        echo "$(date +%H:%M:%S) ${code}" >> "$logf"
        sleep 0.2
      done
    ) &
    echo $! > "${logf}.pid"
    ;;
  stop)
    kill "$(cat "${logf}.pid")" 2>/dev/null || true
    rm -f "${logf}.pid"
    total=$(wc -l < "$logf" | tr -d ' ')
    ok=$(grep -c ' 200$' "$logf" || true)
    echo "user traffic during the experiment: ${total} requests, ${ok} OK, $((total-ok)) failed"
    awk '{print $2}' "$logf" | sort | uniq -c | awk '{printf "  HTTP %s x %s\n", $2, $1}'
    if [[ "$ok" != "$total" ]]; then
      echo "  first failure: $(grep -v ' 200$' "$logf" | head -1)   last failure: $(grep -v ' 200$' "$logf" | tail -1)"
    fi
    ;;
esac
