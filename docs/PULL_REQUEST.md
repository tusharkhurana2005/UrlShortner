# DevOps: build, deploy, observe and operate the URL shortener on Kubernetes

**Student:** Tushar Khurana · **Student ID:** `<fill in>` · **Project:** URL Shortener

- **Repository:** https://github.com/tusharkhurana2005/UrlShortner
- **Baseline commit:** [`12b426b911f0fcad54f184c44ed0040f42bc9d2b`](https://github.com/tusharkhurana2005/UrlShortner/commit/12b426b911f0fcad54f184c44ed0040f42bc9d2b) (this PR's base, `main`, is the baseline), described in [docs/BASELINE.md](docs/BASELINE.md)
- **Final commit:** the head of `devops/production-readiness` (the exact hash is in the submission form)
- **Run instructions:** [README.md](README.md#run-it): `make up`, then open http://localhost:8080

## Main changes

- **App hardening** (`server/`, `client/`): environment config, `/healthz` and `/readyz`, graceful shutdown, Mongo reconnect, Prometheus metrics, OpenTelemetry tracing, JSON logs with trace ids, JWT auth with ownership checks, input validation, rate limiting, `/r/:id` redirect. Fixes the baseline crash on duplicate URLs and the password hash leaking in tokens. 15 integration tests.
- **Containers:** multi-stage, non-root, read-only, digest-pinned images for API and web; 0 fixable HIGH/CRITICAL CVEs.
- **Kubernetes** (`deploy/`): kind cluster as code; Helm chart with API Deployment + HPA + PDB, web Deployment, Mongo StatefulSet + PVC + exporter + backup CronJob, Ingress, default-deny NetworkPolicies, restricted Pod Security; environment overlays instead of copies; pinned platform stack (Traefik, Prometheus/Grafana/Alertmanager, Loki, Alloy, Tempo, metrics-server).
- **CI/CD** (`.github/workflows/ci.yml`): lint, tests, audits, gitleaks, helm lint, kubeconform, hadolint, Trivy (config and images), e2e deploy on kind with smoke test, drift check and an **automatic-rollback test**; publishes SHA-tagged images with provenance from `main`.
- **Release control:** rolling update with zero unavailability, `helm --rollback-on-failure`, `make rollback`, drift detection, and commit → image tag → Helm revision → `/api/version` traceability.
- **Observability:** SLOs measured at the ingress with multi-window burn-rate alerts, cause alerts with runbook links, a dashboard as code, and logs ↔ traces correlation.
- **Operations:** scripts for deploy, smoke test, rollback, drift, backup and restore; repeatable failure demos in `scripts/demos/`.

## Evidence

[docs/evidence/](docs/evidence/README.md) holds raw outputs from the cluster for this commit: deploy and smoke test, security controls enforced, drift remediation, one request traced through logs and traces, a bad release auto-rolled back with no error responses, a MongoDB outage with alerts and recovery, a node drain and a container restart with no failed requests, autoscaling 2→5→2 under load (before and after a liveness fix), a backup/restore drill, and the quality gates. There is also a reproduction of the baseline crash.

Design reasoning: [DECISIONS](docs/DECISIONS.md) · [ARCHITECTURE](docs/ARCHITECTURE.md) · [RUNBOOK](docs/RUNBOOK.md) · [INVESTIGATIONS](docs/INVESTIGATIONS.md)

## Reviewing this PR

The baseline committed `node_modules/` (41k files). This PR leaves those files
untouched to keep the diff reviewable. To see the real changes:

```bash
git diff --stat 12b426b9..HEAD -- . ':!client/node_modules' ':!server/node_modules'
```

## Known limitations

These are listed in the [README](README.md#known-limitations). The main ones:
single-replica MongoDB on node-local storage, no TLS (localhost only),
deployment to the laptop cluster is a manual command, and 3-day metrics
retention.
