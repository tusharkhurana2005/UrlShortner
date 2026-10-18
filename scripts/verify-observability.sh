#!/usr/bin/env bash
# Shows that metrics, logs and traces exist for a real user request and can be
# joined: request -> trace_id in the API log line (Loki) -> trace in Tempo.
source "$(dirname "$0")/lib.sh"
require kubectl curl python3

# Fresh port-forwards every run: an old one dies silently when its pod moves.
pf() { pkill -f "port-forward svc/$2 " 2>/dev/null || true; kubectl -n "${OBS_NAMESPACE}" port-forward "svc/$2" "$1" >/dev/null 2>&1 & }
pf 9090:9090 kube-prometheus-stack-prometheus
pf 9093:9093 kube-prometheus-stack-alertmanager
pf 3100:3100 loki
pf 3200:3200 tempo
pf 3000:80 kube-prometheus-stack-grafana
sleep 3
prom() { curl -s --get http://localhost:9090/api/v1/query --data-urlencode "query=$1"; }

echo "## Metrics (Prometheus)"
echo "  scrape targets:"
curl -s http://localhost:9090/api/v1/targets | python3 -c '
import json,sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    j=t["labels"].get("job","")
    if j.startswith("urlshortener") or j=="traefik-metrics" or "traefik" in j:
        pod, health = t["labels"].get("pod", ""), t["health"]
        print(f"    {j:28s} {pod:38s} {health}")'
echo "  SLIs (recording rules, measured at the ingress):"
for r in urlshortener:request_rate:rate5m urlshortener:error_ratio:rate5m urlshortener:error_ratio:rate1h urlshortener:latency_p95:rate5m; do
  printf '    %-36s %s\n' "$r" "$(prom "$r" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "no data (no traffic in window)")')"
done
echo "  serving version (urlshortener_build_info):"
prom 'count by (version, commit) (urlshortener_build_info)' | python3 -c 'import json,sys; [print("    ", r["metric"]) for r in json.load(sys.stdin)["data"]["result"]]'
echo "  alert rules:"
curl -s http://localhost:9090/api/v1/rules?type=alert | python3 -c '
import json,sys
for g in json.load(sys.stdin)["data"]["groups"]:
    for r in g["rules"]:
        name, sev, state = r["name"], r["labels"].get("severity", ""), r["state"]
        if name.startswith("UrlShortener"): print(f"    {name:38s} {sev:9s} state={state}")'
echo "  Alertmanager currently has $(curl -s http://localhost:9093/api/v2/alerts | python3 -c 'import json,sys; print(len([a for a in json.load(sys.stdin) if a["labels"]["alertname"].startswith("UrlShortener")]))') UrlShortener alert(s)"

echo; echo "## One request, followed through logs and traces"
RID="evidence-$(date +%s)"
curl -s -o /dev/null -H "X-Request-Id: ${RID}" "${APP_URL}/r/doesnotexist"
echo "  sent GET /r/doesnotexist with X-Request-Id: ${RID}; waiting for log shipping..."
for _ in $(seq 1 40); do
  LINE="$(curl -s --get http://localhost:3100/loki/api/v1/query_range \
    --data-urlencode "query={namespace=\"${NAMESPACE}\", component=\"api\"} |= \"${RID}\"" --data-urlencode 'limit=1' \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["values"][0][1] if r else "")')"
  [[ -n "$LINE" ]] && break; sleep 3
done
echo "  Loki log line (labels: namespace, pod, component, level):"
echo "$LINE" | python3 -c 'import json,sys; l=json.load(sys.stdin); print("    " + json.dumps({k: l.get(k) for k in ("level","time","msg","trace_id","span_id")} | {"req.id": l["req"]["id"], "url": l["req"]["url"], "status": l["res"]["statusCode"], "responseTime_ms": l.get("responseTime")}))'
TRACE="$(echo "$LINE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("trace_id",""))')"
sleep 5
echo "  Tempo trace ${TRACE}:"
curl -s "http://localhost:3200/api/traces/${TRACE}" | python3 -c '
import json,sys
d=json.load(sys.stdin); spans=[]
for b in d.get("batches", d.get("resourceSpans", [])):
    svc=[a["value"].get("stringValue") for a in b["resource"]["attributes"] if a["key"]=="service.name"][0]
    for ss in b.get("scopeSpans", []):
        for s in ss["spans"]:
            spans.append((int(s["startTimeUnixNano"]), svc, s["name"], (int(s["endTimeUnixNano"])-int(s["startTimeUnixNano"]))/1e6))
for _, svc, n, ms in sorted(spans): print(f"    {svc:18s} {n:42s} {ms:7.2f} ms")'

echo; echo "## Grafana"
GPW="$(kubectl -n "${OBS_NAMESPACE}" get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
for ds in prometheus loki tempo; do
  printf '  datasource %-11s health: %s\n' "$ds" "$(curl -s -u "admin:${GPW}" "http://localhost:3000/api/datasources/uid/${ds}/health" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status"))')"
done
curl -s -u "admin:${GPW}" "http://localhost:3000/api/search?query=URL%20Shortener" | python3 -c 'import json,sys; [print("  dashboard:", d["title"], "->", d["url"]) for d in json.load(sys.stdin)]'
