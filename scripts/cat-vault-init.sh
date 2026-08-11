#!/usr/bin/env bash
# Print the full Vault operator init JSON (root token and unseal keys).
#
# Usage:
#   bash scripts/cat-vault-init.sh
#   VAULT_INIT_OUTPUT=/path/to/vault-init.json bash scripts/cat-vault-init.sh
#
# Handle output carefully — this file is recovery material.

set -Eeuo pipefail

readonly VAULT_INIT_OUTPUT="${VAULT_INIT_OUTPUT:-/var/lib/vault-bootstrap/vault-init.json}"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  sed -n '1,10p' "$0"
  exit 0
fi

((${#} == 0)) || fail "Unknown argument: $1"

[[ -r "$VAULT_INIT_OUTPUT" ]] \
  || fail "Cannot read VAULT_INIT_OUTPUT: $VAULT_INIT_OUTPUT"

if command -v jq >/dev/null 2>&1; then
  jq . "$VAULT_INIT_OUTPUT"
else
  cat "$VAULT_INIT_OUTPUT"
fi
