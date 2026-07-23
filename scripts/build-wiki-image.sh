#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WIKI_DIR="${REPO_DIR}/apps/wiki"
readonly IMAGE_NAME="${WIKI_IMAGE_NAME:-homeserver-wiki}"
readonly IMAGE_TAG="${WIKI_IMAGE_TAG:-local}"

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

k3s_ctr() {
  if command -v k3s >/dev/null 2>&1; then
    if k3s ctr "$@" 2>/dev/null; then
      return 0
    fi
    sudo k3s ctr "$@"
    return
  fi

  fail "Required command not found: k3s"
}

require_command docker
[[ -d "$WIKI_DIR" ]] || fail "Wiki chart directory not found: $WIKI_DIR"

log "Building ${IMAGE_NAME}:${IMAGE_TAG} from ${WIKI_DIR}"
docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" "$WIKI_DIR"

log "Importing ${IMAGE_NAME}:${IMAGE_TAG} into the k3s container runtime"
docker save "${IMAGE_NAME}:${IMAGE_TAG}" | k3s_ctr -n k8s.io images import -

log "Wiki image ready: ${IMAGE_NAME}:${IMAGE_TAG}"
