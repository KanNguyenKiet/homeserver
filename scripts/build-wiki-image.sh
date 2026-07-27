#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WIKI_DIR="${REPO_DIR}/apps/wiki"
readonly REGISTRY_HOST="${WIKI_REGISTRY_HOST:-git.huukiet.com}"
readonly IMAGE_OWNER="${WIKI_IMAGE_OWNER:-ops}"
readonly IMAGE_NAME="${WIKI_IMAGE_NAME:-homeserver-wiki}"
readonly IMAGE_TAG="${WIKI_IMAGE_TAG:-$(git -C "$REPO_DIR" rev-parse HEAD)}"
readonly IMAGE="${REGISTRY_HOST}/${IMAGE_OWNER}/${IMAGE_NAME}:${IMAGE_TAG}"

log() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

registry_login() {
  if [[ -n "${GITEA_REGISTRY_USER:-}" && -n "${GITEA_REGISTRY_TOKEN:-}" ]]; then
    log "Logging in to ${REGISTRY_HOST} with GITEA_REGISTRY_USER"
    printf '%s' "$GITEA_REGISTRY_TOKEN" | docker login "$REGISTRY_HOST" \
      -u "$GITEA_REGISTRY_USER" --password-stdin
    return
  fi

  if [[ -f "${HOME}/.docker/config.json" ]] \
    && grep -q "\"${REGISTRY_HOST}\"" "${HOME}/.docker/config.json"; then
    return
  fi

  fail "Docker is not logged in to ${REGISTRY_HOST}. Run 'docker login ${REGISTRY_HOST}' or set GITEA_REGISTRY_USER and GITEA_REGISTRY_TOKEN."
}

require_command docker
[[ -d "$WIKI_DIR" ]] || fail "Wiki chart directory not found: $WIKI_DIR"
[[ -n "$IMAGE_TAG" ]] || fail "WIKI_IMAGE_TAG is empty"

log "Building ${IMAGE} from ${WIKI_DIR}"
docker build -t "${IMAGE}" "$WIKI_DIR"

registry_login

log "Pushing ${IMAGE}"
docker push "${IMAGE}"

log "Wiki image ready: ${IMAGE}"
log "Update apps/wiki/values.yaml tag to ${IMAGE_TAG} and push for Argo CD to roll out"
