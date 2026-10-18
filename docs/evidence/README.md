# Evidence

These are raw outputs captured from the live kind cluster. Each file starts with the
commit and the time it was produced. They are produced by `make evidence`
(`scripts/collect-evidence.sh`), which builds the current commit, deploys it
and runs every experiment, so anyone can regenerate them.

**Tested version:** files 01–05 and 07–11 come from commit `1a11338`. The final
commit of the PR only adds this evidence on top, so its code, chart and
scripts are identical (`git diff 1a11338 HEAD --stat` lists only `docs/`).
Two files come from the earlier commit `cf27a7d`, and both say so in their
first lines:

- **06** (MongoDB outage). The fast-burn alert compares the last hour with the
  last 5 minutes, so it can only be demonstrated once no load test sits in
  that hour. Between `cf27a7d` and `1a11338` nothing changed that the outage
  path depends on (readiness, Mongo reconnect, alert rules). The changes were
  repository links, the liveness timeout and the shutdown drain.
- **08a** (autoscaling *before* the liveness fix). Kept deliberately: it is
  the run that exposed 192 × 502 and led to
  [INVESTIGATIONS #10](../INVESTIGATIONS.md#10-load-test-liveness-probe-killed-a-busy-pod-192--502).
  **08** is the same test on the fixed version.

CI evidence: [GitHub Actions runs for this PR](https://github.com/tusharkhurana2005/UrlShortner/actions)
(lint, tests, audits, secret/config/image scans, e2e deploy on kind with smoke
test, drift check and automatic-rollback test).

| File | Proves |
|---|---|
| [00-baseline-crash.txt](00-baseline-crash.txt) | The **unchanged baseline** crashes (exit 1) when the same URL is shortened twice |
| [01-deploy-and-smoke-test.txt](01-deploy-and-smoke-test.txt) | Build → Helm deploy → `helm test` → full user journey through the ingress. The **same commit SHA** appears in the image tag, OCI label, Helm revision, pod labels, `/api/version` and `/version.json` |
| [02-security-verification.txt](02-security-verification.txt) | PSA `restricted` rejects a privileged pod; every container is non-root, read-only, capability-free, seccomp-confined, without a SA token; NetworkPolicies **enforced** (allowed and denied flows probed); `/metrics` not exposed; no credentials in git |
| [03-drift-detection-and-remediation.txt](03-drift-detection-and-remediation.txt) | A manual `kubectl scale` and a deleted NetworkPolicy are detected by `drift-check.sh` and reverted by redeploying the released version |
| [04-observability.txt](04-observability.txt) | Scrape targets up, SLI recording rules, 8 alert rules loaded, Alertmanager wired; **one request followed from its log line (Loki) via `trace_id` to its trace (Tempo)**: Traefik → API → MongoDB `find`; Grafana datasources healthy |
| [05-bad-release-auto-rollback.txt](05-bad-release-auto-rollback.txt) | A release whose pods crash at startup is rolled back automatically by Helm; an old pod restarted mid-release comes up with the old config; no error responses (7 of 361 requests hit the 2s client timeout during a CPU spike on the laptop, analysed at the end of the file); crash reason recovered from Loki after the pods were gone |
| [06-mongodb-outage-and-recovery.txt](06-mongodb-outage-and-recovery.txt) | Symptom → evidence → action → verification for a DB outage: pods NotReady but not restarted, 503 at the ingress, `MongoUnavailable` and `ErrorBudgetFastBurn` firing; automatic reconnect; data written before the outage still there |
| [07-node-drain.txt](07-node-drain.txt) | `kubectl drain` of a worker under traffic: PDBs evict one pod at a time, everything reschedules, **0 failed requests** |
| [08a-autoscaling-before-liveness-fix.txt](08a-autoscaling-before-liveness-fix.txt) | **Before the fix:** under load a CPU-starved pod failed its liveness probe and was killed: 192 × 502 of 95k requests |
| [08-autoscaling.txt](08-autoscaling.txt) | HPA scales the API 2 → 5 under load and back to 2 afterwards, on the fixed version |
| [09-backup-restore-drill.txt](09-backup-restore-drill.txt) | Backup with the CronJob's template, simulated data loss, restore with `restore-backup.sh`, link works again |
| [10-quality-gates.txt](10-quality-gates.txt) | Local run of the CI gates: lint, tests (coverage), `npm audit`, helm lint, kubeconform, hadolint, Trivy image and config scans, gitleaks |
| [11-container-restart-drain.txt](11-container-restart-drain.txt) | The API process in one pod gets SIGTERM (what a liveness restart does): readiness fails, the pod keeps answering while it drains, **0 failed requests**, clean shutdown (fix for [INVESTIGATIONS #10](../INVESTIGATIONS.md#10-load-test-liveness-probe-killed-a-busy-pod-192--502)) |
| [../images/grafana-dashboard.png](../images/grafana-dashboard.png) | The provisioned dashboard after the experiments: version stat, SLIs, deploy annotations, the outage (503s) and the load test |
| [../images/app-login.png](../images/app-login.png), [../images/app-dashboard.png](../images/app-dashboard.png) | The app served through the ingress, used in a real browser (headless Chromium) |
