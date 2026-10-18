# Investigations

Problems found while building and deliberately breaking the system, each
written up as symptom → hypothesis → evidence → change → verification. The
experiments are scripts in `scripts/demos/`, so any of them can be re-run live.

---

## 1. Shortening the same URL twice crashes the server (baseline bug)

- **Symptom:** after a second "Shorten" of a URL already in the list, the API
  stopped answering every request.
- **Hypothesis:** an exception escapes an async Express handler.
- **Evidence:** reproduced on the unchanged baseline
  ([`evidence/00-baseline-crash.txt`](evidence/00-baseline-crash.txt)):
  `TypeError: Assignment to constant variable` at `UrlController.js:17`, and
  the container exits with code 1. The short id was a hash of the URL, so the
  same URL always collides; the "retry" assigned to a `const`; Express 4 does
  not catch rejected promises; Node exits on unhandled rejections.
- **Change:** random base62 ids with a unique index and retry on duplicate key;
  Express 5 (async errors reach the error handler, which returns 500); an
  `unhandledRejection` logger as a last resort.
- **Verification:** integration test *"the same URL can be shortened twice
  (baseline crashed here)"*. On Kubernetes the class of failure is also
  contained: liveness restarts a dead pod and the second replica keeps
  serving.

## 2. The availability SLI was blind to a total outage

- **Symptom:** during the first MongoDB outage drill users got 503 for four
  minutes, but `urlshortener:error_ratio:rate5m` showed no data and the
  burn-rate alert never fired.
- **Hypothesis:** errors that never reach the API can't be counted by the
  API's own metrics.
- **Evidence:** API pods were NotReady, so they received no traffic and the
  API histogram recorded nothing. Traefik's `traefik_service_requests_total` had
  no 503s either. Only `traefik_entrypoint_requests_total{code="503"}` (≈950)
  saw them: a service with no ready backend never receives the request.
- **Change:** enabled Traefik router metrics (`addRoutersLabels`) and moved
  the SLO recording rules to `traefik_router_requests_total` for the `/api`
  and `/r` routers. The API histogram is kept for per-route diagnosis.
- **Verification:** re-ran the drill (evidence 06): the 5m error ratio at the
  ingress is far above the fast-burn threshold (14.4 × 0.5% = 7.2%), and
  `UrlShortenerErrorBudgetFastBurn` fires alongside
  `UrlShortenerMongoUnavailable`.
- **Side note (burn rate working as designed):** in one re-run fast burn did
  *not* fire, because the 1h window still contained an 82k-request load test.
  Four minutes of errors after that much success is a small share of the
  hour. The multi-window rule pages on budget consumption, not on any error.

## 3. When the API has no ready pods, `/api` could be served by the web app

- **Symptom (found by reasoning, then prevented):** Traefik's Kubernetes
  Ingress provider skips routes whose Service has no endpoints by default.
  Requests to `/api/...` would then match the next rule, `/`, and nginx would
  answer `200 index.html`.
- **Impact if unnoticed:** clients get HTML with a 200 instead of an error;
  monitoring sees success.
- **Change:** `providers.kubernetesIngress.allowEmptyServices: true`.
- **Verification:** evidence 06: during the outage `/api/version` returns
  `503 no available server`, not 200.

## 4. Drift remediation was refused (Helm 4 server-side apply)

- **Symptom:** after a manual `kubectl scale deploy/urlshortener-web
  --replicas=1`, redeploying failed with *"conflict with "kubectl" with
  subresource "scale": .spec.replicas"*, and the automatic rollback failed
  with the same error.
- **Hypothesis:** Helm 4 applies manifests server-side; field ownership
  moved to the `kubectl` manager when the field was changed by hand.
- **Evidence:** `helm history` showed revision 9 `superseded` (upgrade failed)
  and revision 10 `failed` (rollback failed), with that message.
- **Change:** `--force-conflicts` in `deploy.sh` and `rollback.sh`. The policy
  is that the reviewed release is the source of truth and wins.
- **Verification:** evidence 03: drift detected (replicas 1 vs 2, a deleted
  NetworkPolicy), remediated by redeploying, `drift-check` clean.

## 5. The ingress was a single point of failure

- **Symptom:** before running the drain experiment, the placement listing
  showed one Traefik pod; a `helm upgrade` of Traefik also produced an `Empty
  reply from server` for one request.
- **Hypothesis:** (a) draining that node drops all traffic; (b) Traefik stops
  accepting on SIGTERM before kube-proxy removes it from the endpoints.
- **Change:** 2 replicas, PDB `maxUnavailable: 1`, strict topology spread.
  The first attempt left a pod Pending because the tainted control-plane node
  counted as an empty domain; fixed with `nodeTaintsPolicy: Honor` and
  `matchLabelKeys: [pod-template-hash]`. Plus `requestAcceptGraceTimeout: 5s`
  and `graceTimeOut: 10s` on the entrypoint.
- **Verification:** evidence 07: `kubectl drain` of a worker with traffic
  running, 0 failed requests.

## 6. Observability tools starved the node

- **Symptom:** after the load test, Alloy's readiness probe failed and log
  lines arrived minutes late. Later Grafana stopped responding.
- **Evidence:** `kubectl top`: Alloy **~10.6 cores** and Grafana **~16 cores**,
  both on the same worker as API pods; neither had a CPU limit. Each request
  log line was ~2 KB because pino-http logged every header, so 82k requests
  meant ~165 MB of logs to ship (API and Traefik).
- **Change:** CPU limits on Alloy (1) and Grafana (1), a deliberate exception
  to the no-CPU-limit rule for the app. Lean request logs (id, method, url,
  status, time: ~230 bytes; the trace has the rest), which also stops
  retaining user agents and client IPs.
- **Verification:** Alloy back to ~40m CPU; Grafana renders the full
  dashboard at ~70m (`docs/images/grafana-dashboard.png`).

## 7. First install failed: backup volume never bound

- **Symptom:** the first `helm install` was rolled back: *"PVC
  urlshortener-mongodb-backup not ready ... Pending"*.
- **Hypothesis:** kind's `standard` StorageClass is `WaitForFirstConsumer`; the
  only consumer is a CronJob that first runs at 02:00, and Helm's `--wait`
  treats a Pending PVC as not ready.
- **Change:** the backup disk is a second `volumeClaimTemplate` on the Mongo
  StatefulSet. It binds with the pod (on the same node, as RWO local-path
  requires) but is **not mounted** into the mongodb container.
- **Verification:** install succeeds; backup and restore drill (evidence 09).

## 8. HPA showed `<unknown>` and `FailedGetScale: Unauthorized`

- **Symptom:** after the node drain, the HPA showed `cpu: <unknown>/70%`, and
  older events said `Unauthorized`.
- **Evidence:** metrics-server had been evicted by the drain and was
  restarting (*"stale GroupVersion discovery: metrics.k8s.io/v1beta1"*). The
  `Unauthorized` events were from when the laptop slept.
- **Change:** none needed. It recovered once metrics-server was Ready. A
  production cluster would run metrics-server with 2 replicas and a PDB.
- **Verification:** HPA reported 23%/70% and scaled normally afterwards
  (evidence 08: 2→5→2).

## 9. A bad release could break the old pods too

- **Symptom:** the crash log recovered from Loki during the bad-release demo
  showed `level:verbose` crashes in pods of the **old, good** ReplicaSet as
  well as the new one. After the rollback, pods of the "bad" ReplicaSet were
  Ready.
- **Hypothesis:** both ReplicaSets read the same ConfigMap. Helm updates it in
  place at the start of the release, so the old pods are only safe until they
  restart.
- **Evidence:** at the start of the next drill the good ReplicaSet had a pod
  with 4 restarts. The old pods' env came from `envFrom: configMapRef` with a
  single name, shared by every revision. Restoring the ConfigMap in the
  rollback also "healed" the bad ReplicaSet's pods, which only differed by
  their checksum annotation.
- **Change:** the API's settings are now plain `env` in the pod template; the
  ConfigMap is gone. Config is versioned with the ReplicaSet, and a rollback
  restores code and config atomically.
- **Verification:** `scripts/demos/bad-release.sh` now deletes an old pod
  *while* the bad release is in progress and checks that its replacement
  starts with the old config and becomes Ready (evidence 05).

## 10. Load test: liveness probe killed a busy pod (192 × 502)

- **Symptom:** one autoscaling run reported `Failed requests: 192 (Non-2xx)`
  out of 95k. Prometheus showed **no** 5xx at all for that window.
- **Evidence:**
  - Traefik access logs (Loki): exactly 192 × `502` on `/api/version`, all
    within 4 seconds.
  - Kubernetes events for one API pod: *"Liveness probe failed ... context
    deadline exceeded"*, then *"Container api failed liveness probe, will be
    restarted"*.
  - The pod's own logs: `Shutting down` (SIGTERM), then `Forced exit after
    grace period` 10s later. Memory was 85 MiB of 256 MiB, so not OOM.
- **Root cause (three parts):**
  1. The node was CPU-saturated (load test + monitoring on a laptop). The pod
     answered `/healthz` slower than the 2s timeout three times, so
     Kubernetes killed a **slow but healthy** process, which added load.
  2. A *container restart* doesn't remove the pod from the Service (only
     failing readiness does). Traefik kept sending requests over its
     keep-alive connections, and the app closed its listener straight away:
     502s.
  3. Prometheus missed it. Traefik creates the `code="502"` counter series
     the first time a 502 happens, and `rate()`/`increase()` can't see
     increments before a series' first sample.
- **Change:** liveness timeout 5s × 6 failures (~60s); on SIGTERM the app now
  fails readiness but keeps serving for 12s with `Connection: close`, then
  closes idle connections and drains; a dashboard panel counts ingress 5xx
  from the access logs (Loki), which sees every request.
- **Verification:** autoscaling re-run under the same load (evidence 08) and
  test *"requests are still served while draining, with Connection: close"*.

