# Evidence

These are raw outputs captured from the live kind cluster and the CI pipeline. Each file
starts with the commit and the time it was produced. Files 01–10 are produced in
one run by `make evidence` (`scripts/collect-evidence.sh`), which builds the
current commit, deploys it and runs every experiment, so anyone can regenerate
them.

| File | Proves |
|---|---|
| [00-baseline-crash.txt](00-baseline-crash.txt) | The **unchanged baseline** crashes (exit 1) when the same URL is shortened twice |
| [01-deploy-and-smoke-test.txt](01-deploy-and-smoke-test.txt) | Build → Helm deploy → `helm test` → full user journey through the ingress. The **same commit SHA** appears in the image tag, OCI label, Helm revision, pod labels, `/api/version` and `/version.json` |
| [02-security-verification.txt](02-security-verification.txt) | PSA `restricted` rejects a privileged pod; every container is non-root, read-only, capability-free, seccomp-confined, without a SA token; NetworkPolicies **enforced** (allowed and denied flows probed); `/metrics` not exposed; no credentials in git |
| [03-drift-detection-and-remediation.txt](03-drift-detection-and-remediation.txt) | A manual `kubectl scale` and a deleted NetworkPolicy are detected by `drift-check.sh` and reverted by redeploying the released version |
| [04-observability.txt](04-observability.txt) | Scrape targets up, SLI recording rules, 8 alert rules loaded, Alertmanager wired; **one request followed from its log line (Loki) via `trace_id` to its trace (Tempo)**: Traefik → API → MongoDB `find`; Grafana datasources healthy |
| [05-bad-release-auto-rollback.txt](05-bad-release-auto-rollback.txt) | A release whose pods crash at startup is rolled back automatically by Helm; **0 failed user requests** during it; crash reason recovered from Loki after the pods were gone |
| [06-mongodb-outage-and-recovery.txt](06-mongodb-outage-and-recovery.txt) | Symptom → evidence → action → verification for a DB outage: pods NotReady but not restarted, 503 at the ingress, `MongoUnavailable` and `ErrorBudgetFastBurn` firing; automatic reconnect; data written before the outage still there |
| [07-node-drain.txt](07-node-drain.txt) | `kubectl drain` of a worker under traffic: PDBs evict one pod at a time, everything reschedules, **0 failed requests** |
| [08-autoscaling.txt](08-autoscaling.txt) | HPA scales the API 2 → 5 under load and back to 2 afterwards; 0 failed requests in the load test |
| [09-backup-restore-drill.txt](09-backup-restore-drill.txt) | Backup with the CronJob's template, simulated data loss, restore with `restore-backup.sh`, link works again |
| [10-quality-gates.txt](10-quality-gates.txt) | Local run of the CI gates: lint, tests (coverage), `npm audit`, helm lint, kubeconform, hadolint, Trivy image and config scans, gitleaks |
| [../images/grafana-dashboard.png](../images/grafana-dashboard.png) | The provisioned dashboard after the experiments: version stat, SLIs, deploy annotations, the outage (503s) and the load test |
| [../images/app-login.png](../images/app-login.png), [../images/app-dashboard.png](../images/app-dashboard.png) | The app served through the ingress, used in a real browser (headless Chromium) |
