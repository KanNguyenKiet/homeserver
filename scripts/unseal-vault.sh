#!/usr/bin/env bash

set -Eeuo pipefail

readonly VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
readonly VAULT_POD="${VAULT_POD:-vault-0}"
readonly VAULT_ADDR="http://127.0.0.1:8200"
readonly WAIT_TIMEOUT="${VAULT_WAIT_TIMEOUT:-300s}"

UNSEAL_KEY=""

cleanup() {
  unset UNSEAL_KEY
}

trap cleanup EXIT

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

vault_status() {
  local status

  status="$(
    kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
      env VAULT_ADDR="$VAULT_ADDR" vault status -format=json 2>/dev/null || true
  )"

  [[ -n "$status" ]] || fail "Unable to read Vault status from $VAULT_NAMESPACE/$VAULT_POD"
  jq -e . >/dev/null <<<"$status" || fail "Vault returned invalid status JSON"
  printf '%s\n' "$status"
}

for command_name in kubectl jq; do
  require_command "$command_name"
done

kubectl wait pod/"$VAULT_POD" -n "$VAULT_NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running --timeout="$WAIT_TIMEOUT"

status="$(vault_status)"
[[ "$(jq -r '.initialized' <<<"$status")" == "true" ]] \
  || fail "Vault has not been initialized; run scripts/bootstrap-vault.sh"

if [[ "$(jq -r '.sealed' <<<"$status")" == "false" ]]; then
  printf 'Vault is already unsealed.\n'
  exit 0
fi

threshold="$(jq -r '.t' <<<"$status")"
[[ "$threshold" =~ ^[1-9][0-9]*$ ]] || fail "Invalid unseal threshold: $threshold"

for ((index = 1; index <= threshold; index++)); do
  read -r -s -p "Unseal key share $index of $threshold: " UNSEAL_KEY
  printf '\n'
  [[ -n "$UNSEAL_KEY" ]] || fail "Unseal key cannot be empty"

  printf '%s' "$UNSEAL_KEY" | \
    kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
      env VAULT_ADDR="$VAULT_ADDR" vault write sys/unseal key=- >/dev/null
  unset UNSEAL_KEY

  status="$(vault_status)"
  if [[ "$(jq -r '.sealed' <<<"$status")" == "false" ]]; then
    break
  fi
done

[[ "$(jq -r '.sealed' <<<"$status")" == "false" ]] \
  || fail "Vault is still sealed"

kubectl wait pod/"$VAULT_POD" -n "$VAULT_NAMESPACE" \
  --for=condition=Ready --timeout="$WAIT_TIMEOUT"
printf 'Vault is unsealed and Ready.\n'
