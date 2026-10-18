#!/usr/bin/env bash
# Shared settings for the scripts in this directory. Override any of these with
# environment variables, e.g. NAMESPACE=staging ./scripts/deploy.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-urlshortener}"
NAMESPACE="${NAMESPACE:-urlshortener}"
OBS_NAMESPACE="${OBS_NAMESPACE:-observability}"
RELEASE="${RELEASE:-urlshortener}"
CHART_DIR="${ROOT_DIR}/deploy/helm/urlshortener"
APP_URL="${APP_URL:-http://localhost:8080}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
require() { for c in "$@"; do command -v "$c" >/dev/null || fail "missing required tool: $c"; done; }
