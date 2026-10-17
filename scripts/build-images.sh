#!/usr/bin/env bash
# Builds the API and web images tagged with the git commit, then loads them
# into the kind cluster. The tag is the link between a running pod and the
# exact source that built it.
source "$(dirname "$0")/lib.sh"
require docker git

GIT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
TAG="${TAG:-$(git -C "${ROOT_DIR}" rev-parse --short=7 HEAD)}"
# An image built from uncommitted changes must never look like a real commit.
# node_modules is ignored: it is excluded from the Docker build context.
if [[ -z "${ALLOW_DIRTY:-}" ]] && [[ -n "$(git -C "${ROOT_DIR}" status --porcelain -- server client ':!server/node_modules' ':!client/node_modules')" ]]; then
  TAG="${TAG}-dirty"
fi
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
REGISTRY="${REGISTRY:-}"
prefix="${REGISTRY:+${REGISTRY}/}"

for component in api web; do
  dir=server; [[ "$component" == web ]] && dir=client
  image="${prefix}urlshortener-${component}:${TAG}"
  log "Building ${image}"
  docker build \
    --build-arg APP_VERSION="${TAG}" \
    --build-arg GIT_COMMIT="${GIT_COMMIT}" \
    --build-arg BUILD_TIME="${BUILD_TIME}" \
    -t "${image}" "${ROOT_DIR}/${dir}"
  if [[ -z "${NO_KIND_LOAD:-}" ]]; then
    log "Loading ${image} into kind cluster '${CLUSTER_NAME}'"
    kind load docker-image "${image}" --name "${CLUSTER_NAME}"
  fi
done

echo "${TAG}" > "${ROOT_DIR}/.last-built-tag"
log "Built tag ${TAG}"
