# One entry point for the whole lifecycle. `make help` lists targets.
SHELL := /bin/bash
TAG ?= $(shell cat .last-built-tag 2>/dev/null)
REGISTRY ?= ghcr.io/tusharkhurana2005

.PHONY: help up cluster secrets platform build deploy deploy-release smoke test lint scan \
        rollback drift backup restore verify evidence grafana prometheus status down

help: ## Show this help
	@grep -E '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-15s\033[0m %s\n",$$1,$$2}'

up: cluster secrets platform build deploy smoke ## Everything from zero: cluster, platform, build, deploy, verify

cluster: ## Create the local kind cluster
	./scripts/cluster-up.sh

secrets: ## Generate credentials inside the cluster (never on disk)
	./scripts/create-secrets.sh

platform: ## Install ingress, metrics-server, Prometheus/Grafana/Loki/Tempo/Alloy
	./scripts/platform-up.sh

build: ## Build images tagged with the git SHA and load them into kind
	./scripts/build-images.sh

deploy: ## Deploy TAG (default: last build) with auto-rollback + helm test
	./scripts/deploy.sh $(TAG)

deploy-release: ## Deploy an image published by CI: make deploy-release TAG=<sha>
	EXTRA_HELM_ARGS="--set image.registry=$(REGISTRY)" ENVIRONMENT=release ./scripts/deploy.sh $(TAG)

smoke: ## End-to-end user journey through the ingress
	./scripts/smoke-test.sh http://localhost:8080 $(TAG)

test: ## Unit/integration tests (API + web)
	cd server && npm ci --ignore-scripts && npm run lint && npm test
	cd client && npm ci --ignore-scripts && CI=true npm test -- --watchAll=false

lint: ## Helm lint, manifest schema validation, Dockerfile lint
	for env in deploy/helm/urlshortener/environments/*.yaml; do helm lint deploy/helm/urlshortener --strict -f $$env --set image.tag=lint; done
	helm template urlshortener deploy/helm/urlshortener --set image.tag=lint | kubeconform -strict -summary -kubernetes-version 1.34.0 -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
	hadolint server/Dockerfile client/Dockerfile

scan: ## Secret scan, config scan, image vulnerability scan
	gitleaks git . --redact --no-banner
	trivy config --severity HIGH,CRITICAL --exit-code 1 --skip-dirs client/node_modules,server/node_modules .
	trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 urlshortener-api:$(TAG)
	trivy image --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 urlshortener-web:$(TAG)

rollback: ## Roll back to the previous Helm revision (or REVISION=n)
	./scripts/rollback.sh $(REVISION)

drift: ## Compare the deployed release with the live cluster
	./scripts/drift-check.sh

backup: ## Run the backup CronJob now
	kubectl -n urlshortener create job backup-manual-$$(date +%s) --from=cronjob/urlshortener-mongodb-backup

restore: ## Restore the newest backup (or ARCHIVE=<file>)
	./scripts/restore-backup.sh $(ARCHIVE)

verify: ## Prove security controls and observability work on the live cluster
	./scripts/verify-security.sh
	./scripts/verify-observability.sh

evidence: ## Rebuild, redeploy and regenerate docs/evidence (~25 min, runs failure demos)
	./scripts/collect-evidence.sh

grafana: ## Open Grafana on http://localhost:3000 (prints the admin password)
	@echo "user: admin  password: $$(kubectl -n observability get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
	kubectl -n observability port-forward svc/kube-prometheus-stack-grafana 3000:80

prometheus: ## Open Prometheus on http://localhost:9090
	kubectl -n observability port-forward svc/kube-prometheus-stack-prometheus 9090:9090

status: ## What is running, which version, release history
	@curl -s http://localhost:8080/api/version; echo
	kubectl -n urlshortener get pods,svc,ingress,hpa,pdb,pvc -o wide
	helm history urlshortener -n urlshortener --max 5

down: ## Delete the kind cluster (all data in it is lost)
	kind delete cluster --name urlshortener
