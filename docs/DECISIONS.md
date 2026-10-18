# Decisions and trade-offs

Each section covers what was chosen, why it fits this application, the
credible alternatives, and when the choice should change.

## 1. Environment: kind on a laptop

**Chosen:** kind v0.33 (Kubernetes 1.37) with 1 control-plane and 2 workers,
defined in `deploy/kind/cluster.yaml`. Only `127.0.0.1:8080` is published.

**Why:** It's free and reproducible from a file, and it's the same cluster
definition CI uses (`helm/kind-action` with the same config). Two workers make
the node-level features real: topology spread, PDBs during `kubectl drain`, and
pods rescheduling.

**Alternatives:** minikube (single node by default; addons hide what is
installed); Docker Desktop Kubernetes (not reproducible in CI); a managed
cluster (EKS/GKE, costs money, needs Terraform, which this course excludes).

**Would change when:** real users. Then a managed cluster gives real load
balancers, storage that survives node loss, and multiple availability zones.

## 2. Workload types

| Component | Choice | Reasoning |
|---|---|---|
| API | Deployment | Stateless: users and links live in Mongo, the session is a JWT. Any replica can serve any request, so replicas are interchangeable and can scale |
| Web | Deployment | Static files. A CDN or object storage would be cheaper in production, but keeping it in the cluster keeps one origin and no CORS |
| MongoDB | StatefulSet, 1 replica | Stable identity (`mongodb-0`) and a PVC that follows the pod. `persistentVolumeClaimRetentionPolicy: Retain` keeps the data even if the StatefulSet is deleted |
| Backup | CronJob | Scheduled, run-to-completion, `concurrencyPolicy: Forbid` |

**Why not a 3-member Mongo replica set?** One user, one laptop: a replica set
triples memory for availability nobody needs here. The cost is that **MongoDB
is the main single point of failure**: during its outage `/api` returns 503
(evidence 06). The local-path volume also pins it to one node, so a drain of
that node means downtime. For production: a replica set (via the MongoDB
operator) or a managed database (Atlas), and the API connection string lists
all members.

**Why not a managed DB even locally?** The project is about operating the
system. Running the database in-cluster makes storage, identity, backups and
least-privilege users visible.

## 3. Health checks

| Probe | API | Reason |
|---|---|---|
| startup | `/healthz`, up to 60s | Liveness must not kill a slow boot |
| liveness | `/healthz` (no DB check) | Restart only when *this process* is broken. If liveness checked Mongo, a DB outage would restart every API pod in a loop and make recovery slower (evidence 06: restarts stay 0) |
| readiness | `/readyz` = Mongo connected and not shutting down | A pod that cannot serve should not receive traffic |

**Trade-off I accepted:** because readiness depends on Mongo, a DB outage removes
*all* API pods, so even `/api/version` returns 503 from Traefik. The
alternative is to keep pods Ready and return a JSON 503 per request. That gives
nicer errors, but traffic then keeps flowing to pods that can't do useful work.
Every useful endpoint of a URL shortener needs the DB, so I chose readiness.

**Graceful shutdown:** `preStop: sleep 5` lets endpoints and Traefik stop
routing to the pod first. On SIGTERM the app fails readiness, finishes
in-flight requests, closes Mongo and flushes traces (`server/index.js`).
Evidence 05 and 07: 0 failed requests across rollouts and drains.

## 4. Resources and scaling

- **Requests** (API 50m CPU / 96Mi) are what the scheduler and HPA use.
  **Memory limits** are set (256Mi) so a leak kills one pod, not the node.
- **No CPU limit on the app.** CPU limits cause CFS throttling, which shows up
  as latency spikes even when the node is idle. The request already guarantees
  a share. **Exception: observability tooling.** Alloy (about 10 cores while catching up
  on logs) and Grafana (16 cores) both consumed whole nodes during the
  experiments, so they *have* CPU limits. Tools should fall behind, not starve
  the app.
- **HPA on CPU, 2–5 replicas, 70% of request.** Evidence 08: 2→5 under load, back
  to 2 after the 120s scale-down stabilization. Utilization is
  relative to the *request*, which is deliberately small. In production I'd
  size the request from observed usage and consider scaling on request rate or
  latency (custom metrics via prometheus-adapter or KEDA) instead of CPU.
- **minReplicas 2 + PDB minAvailable 1 + topology spread** means a node drain
  or a single crash never takes the API to zero.

## 5. Configuration: one chart, small environment overlays

**Chosen:** a single Helm chart (`deploy/helm/urlshortener`). `values.yaml`
describes the real deployment, and `environments/{local,ci,release}.yaml`
override only what differs: replicas, add-ons that need CRDs, image registry.
`helm lint` and `kubeconform` run for every environment in CI.

**Why Helm over Kustomize:** I need computed values (the error budget from the
SLO target, the Mongo host from the release name, conditional components),
packaging with `appVersion`, release history, and `--rollback-on-failure`.
Kustomize patches would duplicate more and has no release or rollback concept.

**Avoiding drifting copies:** there are no per-environment manifest copies. CI
deploys the same chart with `ci.yaml`. The platform charts are pinned to exact
versions in `scripts/platform-up.sh` with values in `deploy/platform/`.

**Config is versioned with the release:** non-secret settings are environment
variables in the Deployment's pod template, not a shared ConfigMap. Each
ReplicaSet therefore carries the exact config it was released with. I started
with a ConfigMap (with a checksum annotation to roll pods), and a failure
experiment showed why that's wrong: a bad release overwrites the shared
ConfigMap in place, and any *old* pod that restarts mid-rollout picks up the
bad config and crashes too ([INVESTIGATIONS #9](INVESTIGATIONS.md#9-a-bad-release-could-break-the-old-pods-too)).
For larger config files, the same guarantee comes from immutable ConfigMaps
with a content hash in the name (like Kustomize's `configMapGenerator`).
Secrets are shared objects with the same property, so rotating them means
creating a new Secret name and rolling the pods to it (below).

## 6. CI/CD and the automation boundary

**Pipeline** (`.github/workflows/ci.yml`), run on every PR and push to `main`:

1. Fast checks in parallel: API (eslint, 15 integration tests against
   in-memory Mongo, `npm audit`), web (test, build, audit), config (gitleaks
   over full history, helm lint ×3, kubeconform with CRD schemas, hadolint,
   Trivy config).
2. Images built once per commit (tag = SHA), Trivy-scanned, passed between
   jobs as artifacts.
3. **e2e**: a real kind cluster, the same scripts as local (`platform-up.sh
   --ingress-only`, `create-secrets.sh`, `deploy.sh`, `smoke-test.sh`,
   `drift-check.sh`). It then **deploys a deliberately broken tag and asserts
   that Helm rolls back and users still get the old version**. The rollback
   path is tested on every PR, not just assumed.
4. **publish** (main only): pushes *the exact images that passed e2e* to GHCR,
   with build-provenance attestations and the chart packaged with
   `appVersion=SHA`.

**Where automation stops, and why:** the target cluster runs on my laptop
behind NAT, so a GitHub-hosted runner cannot reach it. The **approval gate is
the pull request review**, and the **deployment is a deliberate human command**:
`make deploy-release TAG=<sha>` (or `make build deploy` locally). It's one
command, fully scripted, idempotent and self-verifying (rollout, `helm test`,
smoke test).

**Alternatives considered:**

- *Argo CD / Flux (GitOps pull):* the cluster pulls from git, so no inbound
  access is needed. It also gives continuous drift correction (self-heal),
  which is attractive. I didn't use it because it adds ~0.5–1 GB of
  controllers to a laptop cluster that already runs a full observability stack,
  and CI would have to commit image-tag bumps back to git. **I'd switch to it**
  as soon as there's more than one environment or more than one person
  deploying.
- *Self-hosted runner on the laptop:* would allow push-based CD, but it gives
  GitHub-triggered code a shell on my machine. Not worth it for one user.
- *GitHub Environments with required reviewers:* the right place for an
  approval gate once the deploy job can reach a cluster.

**Supply chain:** actions pinned to commit SHAs, `permissions: contents: read`
by default (only `publish` gets `packages: write`), base images pinned by
digest, Dependabot for npm, Docker and actions, `npm ci --ignore-scripts`.

## 7. Release strategy, rollback and traceability

**Chosen:** rolling update with `maxSurge 1, maxUnavailable 0`, gated by
readiness, plus Helm `--rollback-on-failure`.

**Why:** a stateless API behind a load balancer, one cluster, low traffic.
Rolling with readiness gives zero-downtime deploys and automatic protection
against releases that crash or fail probes (evidence 05: no user request failed
while a broken release was attempted and rolled back).

**Recovering from a bad release that is healthy but wrong** (passes probes
but has a logic bug): `make rollback` (`helm rollback` to the previous
revision, then a smoke test against the expected version). `helm history`
shows each revision's image tag and chart commit.

**Alternatives:**

- *Blue-green:* instant switch and instant rollback, but double resources and a
  shared database means schema changes must stay backward compatible anyway.
- *Canary (Argo Rollouts / Flagger):* shifts a percentage of traffic and
  automatically analyzes error rate and latency against the SLO. **This is what
  I'd add with real traffic.** With ~0 requests per second a canary has
  nothing to measure.
- *Feature flags:* decouple deploy from release for risky features. Not needed
  for this feature set.

**Database changes:** Mongoose is schemaless, and changes here are additive
(new fields, new indexes). With a rolling update old and new pods run at the
same time, so any change must be backward compatible (expand → migrate →
contract).

**Traceability:** commit SHA → image tag + OCI `revision` label → Helm
revision (`APP VERSION`, description `image=<sha> chart=<sha>`) → pod label
`app.kubernetes.io/version` → `/api/version`, `/version.json` and the
`urlshortener_build_info` metric (shown on the dashboard, with a deploy
annotation). The alert `UrlShortenerMultipleVersionsServing` fires if more
than one version serves for 15 minutes.

**Drift:** `scripts/drift-check.sh` compares the manifest of the deployed Helm
release with the live objects (`kubectl diff`). It runs in CI after deploy and
on demand. Evidence 03: a manual `kubectl scale` and a deleted NetworkPolicy
were detected and reverted by redeploying.
*Finding:* Helm 4 uses server-side apply, so a field changed by `kubectl
scale` becomes owned by kubectl and Helm refused to overwrite it. Even the
automatic rollback failed. `--force-conflicts` encodes the decision that **the
reviewed release wins**.

## 8. Observability and reliability

**Signals:**

| Signal | Implementation | Used for |
|---|---|---|
| Metrics | prom-client RED histogram per route, business counters, `mongo_up`, `build_info`; Traefik router metrics; mongodb_exporter; kube-state-metrics; node-exporter | SLOs, alerts, dashboard, capacity |
| Logs | pino JSON → stdout → Alloy → Loki, `level` as label, `trace_id` in every line | What happened to *this* request, crash reasons after the pod is gone (evidence 05) |
| Traces | OpenTelemetry (HTTP, Express, MongoDB, pino) → Tempo; Traefik starts the trace | Where time goes: ingress vs app vs DB (evidence 04) |

**What "healthy" means (SLOs):** 99.5% of `/api` and `/r` requests return
non-5xx, and p95 latency stays under 500ms. Both are measured **at the ingress**.

**Finding (why the ingress):** first I measured at the API. During the Mongo
outage every API pod was NotReady, so *the API saw no traffic and reported 0%
errors* while users got 503s. Then I tried Traefik's service metrics. They
also miss it, because a service with no ready backend never receives the
request. **Router-level metrics** count every request matched by the route,
so they're the user's view. The API's own histogram stays for per-route
diagnosis.

**Alerts** (`templates/prometheusrule.yaml`), each with a runbook link:

- Multi-window burn rate (Google SRE workbook): **fast burn** (14.4× budget,
  1h and 5m windows, page) and **slow burn** (6×, 6h and 30m, ticket). Burn
  rate pages on user impact in proportion to the budget, instead of on a raw
  threshold that is either noisy or late. Evidence 06: fast burn fired during
  the outage.
- Cause-oriented alerts that make the response obvious: `MongoUnavailable`,
  `ApiDown`, `PodRestarting`, `HighLatency`, `MultipleVersionsServing`,
  `BackupStale`.
- Alertmanager routes everything to a `null` receiver locally. In production
  this would go to Slack or PagerDuty, with critical alerts paging.

**Verifying recovery:** an alert resolving is necessary but not sufficient.
Recovery is verified by the scripted user journey (`smoke-test.sh`), the SLI
returning under target, and (for data incidents) checking a known record
(evidence 06 checks a link written before the outage, evidence 09 a restored
one).

**Retention:** 3 days of metrics and logs. That's enough for a laptop, but the
30-day SLO window can't actually be computed. The dashboard's error-budget
panel says "3d window" for that reason. Production: longer retention or
remote storage (Thanos or Mimir).

## 9. Security

| Layer | Control |
|---|---|
| Secrets | Generated *inside* the cluster by `scripts/create-secrets.sh` (`openssl rand`); never in git, never on disk, never printed. Mongo credentials and the JWT key are separate Secrets. Mongo users are least privilege (app: `readWrite` on `Urls`; exporter: `clusterMonitor`; root used only by the init script). Production: External Secrets Operator with Vault or a cloud secret manager, plus rotation |
| Admission | Namespace label `pod-security.kubernetes.io/enforce=restricted`. A privileged pod is rejected by the API server (evidence 02) |
| Containers | Non-root numeric UIDs, read-only root filesystem, all capabilities dropped, no privilege escalation, `RuntimeDefault` seccomp, no service-account token (the app never calls the K8s API) |
| Network | Default-deny ingress and egress; allow only ingress→web/api, api→mongo, backup→mongo, monitoring→metrics, api→tempo, DNS. The API cannot reach the internet. Verified by probes (evidence 02) |
| Exposure | Only Traefik (NodePort, bound to 127.0.0.1) is reachable. Only `/api`, `/r` and `/` are routed; `/metrics` and probes are cluster-internal. Grafana and Prometheus via `kubectl port-forward` only |
| App | JWT auth with user id from the token, ownership checks, http(s)-only targets, rate limit on login and signup, helmet headers, 10 KB body limit, no password hashes in responses or tokens, uniform 401 |
| Images | Multi-stage, prod deps only, no npm in runtime, OS packages upgraded, digest-pinned bases; Trivy gate on fixable HIGH/CRITICAL (currently 0) |
| Pipeline | gitleaks (full history), Trivy config, `npm audit`, SHA-pinned actions, least-privilege tokens, provenance attestations, Dependabot |

**Not done (known gaps):** TLS on the ingress (localhost only; production would
use cert-manager with Let's Encrypt), image signature verification at
admission (Kyverno or Sigstore policy-controller), encryption of the Mongo
volume at rest, and secret rotation.

## 10. What would change under different requirements

| If… | I would… |
|---|---|
| Real users / multiple environments | Managed K8s across 3 AZs, Argo CD with an app per environment, GitHub Environments with required reviewers for prod |
| The DB must survive a node loss | 3-member replica set or a managed DB, `podAntiAffinity` across nodes/zones, PDB `minAvailable 2`, backups to object storage with point-in-time recovery |
| Traffic grows 100× | Size requests from real usage, HPA on RPS or latency, a cache in front of `/r` lookups (redirects are read-heavy), CDN for the web app |
| Releases get riskier | Argo Rollouts canary with Prometheus analysis on the SLO queries above |
| Compliance requirements | TLS everywhere (mTLS with a service mesh), signed images enforced at admission, audit logging, secret rotation, encrypted volumes |
| A team instead of one person | CODEOWNERS, branch protection requiring the CI checks, on-call rotation fed by Alertmanager |
