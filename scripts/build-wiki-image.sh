#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WIKI_DIR="${REPO_DIR}/apps/wiki"
readonly REGISTRY_HOST="${WIKI_REGISTRY_HOST:-git.huukiet.com}"
readonly IMAGE_OWNER="${WIKI_IMAGE_OWNER:-ops}"
readonly IMAGE_NAME="${WIKI_IMAGE_NAME:-homeserver-wiki}"
readonly IMAGE_TAG="${WIKI_IMAGE_TAG:-latest}"
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

log "Building ${IMAGE} from ${WIKI_DIR}"
docker build -t "${IMAGE}" "$WIKI_DIR"

if git -C "$REPO_DIR" rev-parse --short HEAD >/dev/null 2>&1; then
  readonly SHA_TAG="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  log "Tagging ${REGISTRY_HOST}/${IMAGE_OWNER}/${IMAGE_NAME}:${SHA_TAG}"
  docker tag "${IMAGE}" "${REGISTRY_HOST}/${IMAGE_OWNER}/${IMAGE_NAME}:${SHA_TAG}"
else
  readonly SHA_TAG=""
fi

registry_login

log "Pushing ${IMAGE}"
docker push "${IMAGE}"

if [[ -n "$SHA_TAG" ]]; then
  log "Pushing ${REGISTRY_HOST}/${IMAGE_OWNER}/${IMAGE_NAME}:${SHA_TAG}"
  docker push "${REGISTRY_HOST}/${IMAGE_OWNER}/${IMAGE_NAME}:${SHA_TAG}"
fi

log "Wiki image ready: ${IMAGE}"
