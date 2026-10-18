# Runbook

Every alert in `deploy/helm/urlshortener/templates/prometheusrule.yaml` links
to a section here. Each section covers what the alert means, how to confirm it,
what to do, and how to know it is fixed.

Common tools:

```bash
make status                     # version, pods, ingress, HPA, PDB, PVC, Helm history
make grafana                    # dashboard "URL Shortener — Service Overview" on :3000
make prometheus                 # :9090, Alerts tab
kubectl -n urlshortener get events --sort-by=.lastTimestamp | tail -20
./scripts/smoke-test.sh         # the user journey; the final word on "is it fixed?"
```

Logs in Grafana → Explore → Loki: `{namespace="urlshortener", component="api", level=~"warn|error"}`.
Clicking a line's `trace_id` opens the trace in Tempo.

---

## Error budget burn

`UrlShortenerErrorBudgetFastBurn` (critical) / `UrlShortenerErrorBudgetSlowBurn` (warning)

**Meaning:** a share of `/api` and `/r` requests at the ingress are failing with
5xx, fast enough to exhaust the 0.5% monthly budget in about 2 days (fast) or
5 days (slow). This is the user-impact alert; find the cause below.

**Confirm:**
1. Dashboard → *5xx error ratio vs SLO budget* and *Requests/s by status code
   (ingress)*. Are the errors **503** (no ready backend) or **500** (the app
   failing)?
2. 503 → check `Ready API pods` / `MongoDB (as seen by API)`, then go to
   [MongoDB unavailable](#mongodb-unavailable) or [API down](#api-down).
3. 500 → *Requests/s by route and status (inside the API)* shows which route
   is failing. Loki `level="error"` gives the stack trace, and its `trace_id`
   shows the failing span (often the Mongo call).

**Act:**
- Started right after a deploy (blue dashed line = deploy annotation)?
  `make rollback`, then investigate calmly.
- Otherwise fix the dependency or route identified above.

**Verify:** `make smoke` passes; `urlshortener:error_ratio:rate5m` is back
under 0.005; the fast-burn alert resolves (its 5m window clears within
minutes; the slow-burn alert takes longer, which is expected).

## High latency

`UrlShortenerHighLatency`: p95 at the ingress above 500ms for 10 minutes.

**Confirm:** dashboard *API latency percentiles* (inside the API) vs *p95 at
ingress*. If inside-API latency is also high, open a slow trace in Tempo and
see whether the time is in `find/insert urls` (Mongo) or in the handler.
- CPU: *CPU by pod* near or above the request, and HPA at max (5)?
  Then this is saturation.
- Mongo: *MongoDB operations/s* and connections spiking?

**Act:** saturation → raise `api.autoscaling.maxReplicas` or the CPU request
in `values.yaml` and redeploy. Slow queries → check that indexes exist
(`shortUrl` unique, `userId`); after a restore, `mongorestore` recreates them.

**Verify:** p95 under 500ms on the dashboard; alert resolves.

## API down

`UrlShortenerApiDown`: Prometheus cannot scrape any API pod.

**Confirm:** `kubectl -n urlshortener get pods -l app.kubernetes.io/component=api`.
- `CrashLoopBackOff` → `kubectl logs --previous`, or Loki for pods that are
  already gone (evidence 05 shows exactly this).
- `ImagePullBackOff` → the tag does not exist or is not loaded into kind
  (`make build`).
- `Pending` → `kubectl describe pod`: resources, or a PDB/node problem.

**Act:** if a release caused it, `make rollback`. `deploy.sh` normally does
this automatically, so check `helm history` for a `failed` revision.

**Verify:** pods Ready, `make smoke`, alert resolves.

## MongoDB unavailable

`UrlShortenerMongoUnavailable`: every API pod reports `urlshortener_mongo_up == 0`.

**Expected symptoms:** API pods `Running` but `0/1` Ready, no restarts (this
is by design: liveness ignores Mongo); users get **503** on `/api` and `/r`;
the static UI still loads. Evidence 06 is a recorded drill of exactly this.

**Confirm:**
```bash
kubectl -n urlshortener get pods,pvc -l app.kubernetes.io/component=mongodb
kubectl -n urlshortener describe pod urlshortener-mongodb-0 | tail -20
kubectl -n urlshortener logs urlshortener-mongodb-0 -c mongodb --tail=50
```
- Pod missing or StatefulSet at 0 replicas → `kubectl -n urlshortener scale sts urlshortener-mongodb --replicas=1`
- `Pending` → its PVC is bound to one node (local-path); is that node up and
  uncordoned? (`kubectl get nodes`, `kubectl uncordon <node>`)
- `CrashLoopBackOff` / OOMKilled → raise `mongodb.resources.limits.memory`;
  check disk space on the volume.
- Auth errors in API logs after someone recreated secrets → the users were
  created with the old passwords at first init; restore the old secret.

**Act:** get the pod Running and Ready. **The API reconnects by itself.** Do
not restart API pods (evidence 06: users were served again within seconds of
Mongo becoming Ready).

**Verify:** `urlshortener_mongo_up` back to 1 on every pod, API pods Ready,
`make smoke`, and a link created *before* the outage still redirects (data on
the PVC survived).

## Pod restarting

`UrlShortenerPodRestarting`: a container restarted more than twice in 15 minutes.

**Confirm:** `kubectl -n urlshortener describe pod <pod>` → *Last State*:
- `OOMKilled` → memory limit too low or a leak (dashboard *Memory working set
  by pod*).
- `Error` with exit code → `kubectl logs <pod> --previous` / Loki.
- Liveness failures in events → the event loop is blocked (CPU starved or a
  hot loop).

**Act:** a crash-looping *new* version → `make rollback`. OOM → raise the
limit in `values.yaml` and redeploy (never `kubectl edit`; see drift).

**Verify:** restart count stops increasing; alert resolves after 15 minutes.

## Multiple versions serving

`UrlShortenerMultipleVersionsServing`: more than one `version` label on
`urlshortener_build_info` for 15 minutes.

**Meaning:** a rollout is stuck (new pods not becoming Ready while
`maxUnavailable: 0` keeps the old ones), or someone changed an image outside
the pipeline.

**Confirm:** `kubectl -n urlshortener get pods -L app.kubernetes.io/version`;
`kubectl -n urlshortener rollout status deploy/urlshortener-api`;
`make drift`.

**Act:** stuck rollout → `make rollback` (or fix and redeploy). Drift →
redeploy the released version with `make deploy TAG=<released tag>`.

**Verify:** one version on the dashboard *Serving version* stat; `make drift`
is clean.

## Backup stale

`UrlShortenerBackupStale`: no successful backup Job in 26 hours.

**Confirm:**
```bash
kubectl -n urlshortener get cronjob,jobs -l app.kubernetes.io/component=mongodb-backup
kubectl -n urlshortener logs job/<latest-backup-job>
```
Common causes: Mongo unavailable at 02:00, the backup volume full, wrong
credentials.

**Act:** fix the cause, then `make backup` to run one immediately.

**Verify:** the Job completes and its log shows `backup written: /backup/urls-<timestamp>.archive.gz`.

## Restore from backup

Use this after data loss or corruption. Evidence 09 is a recorded drill.

```bash
make restore                                   # newest archive
make restore ARCHIVE=urls-20261018T020000Z.archive.gz
```

`scripts/restore-backup.sh` runs a one-off Job with the backup labels (so the
NetworkPolicy allows it to reach Mongo and nothing else) and runs
`mongorestore --drop` for the `Urls` database. **Everything written after the
backup is lost** (RPO up to 24h with the nightly schedule). Lower the RPO
with a more frequent schedule or a replica set with point-in-time recovery.

**Verify:** the restore Job log shows `N document(s) restored successfully. 0
document(s) failed`; a known link redirects again; `make smoke` passes.

## Bad release

The automatic path: `deploy.sh` uses `--rollback-on-failure`, so a release
whose pods do not become Ready within the timeout is rolled back automatically
and `deploy.sh` exits non-zero (evidence 05; CI asserts this on every PR).

The manual path: the release is healthy but wrong (a logic bug):

```bash
helm history urlshortener -n urlshortener      # find the last good revision
make rollback                                  # previous revision, or REVISION=<n>
```

`rollback.sh` verifies the result with the smoke test against the tag it
rolled back to. Then fix forward through a PR. Do not leave the cluster on a
rolled-back revision that differs from `main` for long (`make drift` / the
dashboard's version stat will show it).
