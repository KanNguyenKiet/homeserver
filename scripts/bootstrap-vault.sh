#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
readonly VAULT_POD="${VAULT_POD:-vault-0}"
readonly VAULT_ADDR="http://127.0.0.1:8200"
readonly INIT_KEY_SHARES="${VAULT_INIT_KEY_SHARES:-3}"
readonly INIT_KEY_THRESHOLD="${VAULT_INIT_KEY_THRESHOLD:-2}"
readonly WAIT_TIMEOUT="${VAULT_WAIT_TIMEOUT:-300s}"

ROOT_TOKEN=""
TUNNEL_TOKEN=""
UNSEAL_KEY=""
INIT_TEMP_FILE=""

cleanup() {
  unset ROOT_TOKEN TUNNEL_TOKEN UNSEAL_KEY
  if [[ -n "$INIT_TEMP_FILE" && -f "$INIT_TEMP_FILE" ]]; then
    chmod 600 -- "$INIT_TEMP_FILE" || true
    printf 'WARNING: Vault initialization output was preserved at %s\n' \
      "$INIT_TEMP_FILE" >&2
  fi
}

trap cleanup EXIT

log() {
  printf '\n==> %s\n' "$*"
}

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

choose_init_output() {
  local output_path="${VAULT_INIT_OUTPUT:-}"
  local output_parent
  local resolved_output
  local resolved_repo

  if [[ -z "$output_path" ]]; then
    read -r -p "Absolute path for Vault recovery material (outside this repo): " output_path
  fi

  [[ "$output_path" == /* ]] || fail "VAULT_INIT_OUTPUT must be an absolute path"
  output_parent="$(dirname -- "$output_path")"
  [[ -d "$output_parent" ]] || fail "Output directory does not exist: $output_parent"
  [[ -w "$output_parent" ]] || fail "Output directory is not writable: $output_parent"

  resolved_repo="$(realpath -- "$REPO_DIR")"
  resolved_output="$(realpath -m -- "$output_path")"
  case "$resolved_output" in
    "$resolved_repo" | "$resolved_repo"/*)
      fail "Vault recovery material must not be stored inside the Git repository"
      ;;
  esac

  [[ ! -e "$resolved_output" ]] || fail "Refusing to overwrite existing file: $resolved_output"
  printf '%s\n' "$resolved_output"
}

for command_name in kubectl jq realpath; do
  require_command "$command_name"
done

[[ "$INIT_KEY_SHARES" =~ ^[1-9][0-9]*$ ]] \
  || fail "VAULT_INIT_KEY_SHARES must be a positive integer"
[[ "$INIT_KEY_THRESHOLD" =~ ^[1-9][0-9]*$ ]] \
  || fail "VAULT_INIT_KEY_THRESHOLD must be a positive integer"
((INIT_KEY_THRESHOLD <= INIT_KEY_SHARES)) \
  || fail "VAULT_INIT_KEY_THRESHOLD cannot exceed VAULT_INIT_KEY_SHARES"

log "Waiting for the Vault pod"
kubectl get pod "$VAULT_POD" -n "$VAULT_NAMESPACE" >/dev/null \
  || fail "Vault is not deployed; run deploy.sh first"
kubectl wait pod/"$VAULT_POD" -n "$VAULT_NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running --timeout="$WAIT_TIMEOUT"

status="$(vault_status)"
initialized="$(jq -r '.initialized' <<<"$status")"
sealed="$(jq -r '.sealed' <<<"$status")"

if [[ "$initialized" == "false" ]]; then
  init_output="$(choose_init_output)"

  log "Initializing Vault with $INIT_KEY_SHARES key shares and threshold $INIT_KEY_THRESHOLD"
  umask 077
  INIT_TEMP_FILE="$(mktemp "${init_output}.tmp.XXXXXX")"
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    env VAULT_ADDR="$VAULT_ADDR" vault operator init \
      -key-shares="$INIT_KEY_SHARES" \
      -key-threshold="$INIT_KEY_THRESHOLD" \
      -format=json >"$INIT_TEMP_FILE"

  # Preserve the initialization response before validating it. Vault cannot
  # reproduce unseal keys after a successful initialization.
  mv -- "$INIT_TEMP_FILE" "$init_output"
  INIT_TEMP_FILE=""
  chmod 600 -- "$init_output"

  jq -e \
    --argjson shares "$INIT_KEY_SHARES" \
    --argjson threshold "$INIT_KEY_THRESHOLD" \
    '(.unseal_keys_b64 | length) == $shares and
     .unseal_threshold == $threshold and
     (.root_token | length) > 0' \
    "$init_output" >/dev/null \
    || fail "Vault was initialized, but its recovery output is unexpected. The raw output was preserved at $init_output"

  mapfile -t unseal_keys < <(
    jq -r --argjson threshold "$INIT_KEY_THRESHOLD" \
      '.unseal_keys_b64[:$threshold][]' "$init_output"
  )

  log "Unsealing Vault"
  for UNSEAL_KEY in "${unseal_keys[@]}"; do
    printf '%s' "$UNSEAL_KEY" | \
      kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
        env VAULT_ADDR="$VAULT_ADDR" vault write sys/unseal key=- >/dev/null
  done
  unset UNSEAL_KEY unseal_keys

  ROOT_TOKEN="$(jq -r '.root_token' "$init_output")"

  printf '\nVault recovery material was written to:\n  %s\n' "$init_output"
  printf '%s\n' \
    "Move it to encrypted offline storage, separate the unseal key shares, and delete the local copy."
else
  [[ "$sealed" == "false" ]] \
    || fail "Vault is sealed; run scripts/unseal-vault.sh before configuring it"

  log "Vault is already initialized; existing configuration will be updated"
  read -r -s -p "Vault root token: " ROOT_TOKEN
  printf '\n'
  [[ -n "$ROOT_TOKEN" ]] || fail "Vault root token cannot be empty"
fi

status="$(vault_status)"
[[ "$(jq -r '.sealed' <<<"$status")" == "false" ]] || fail "Vault is still sealed"

read -r -s -p "Cloudflare tunnel token: " TUNNEL_TOKEN
printf '\n'
[[ -n "$TUNNEL_TOKEN" ]] || fail "Cloudflare tunnel token cannot be empty"

log "Configuring Vault KV, Kubernetes authentication, policy, and tunnel token"
{
  printf '%s\n' "$ROOT_TOKEN"
  printf '%s\n' "$TUNNEL_TOKEN"
} | kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh -ec '
  IFS= read -r VAULT_TOKEN
  IFS= read -r TUNNEL_TOKEN
  export VAULT_ADDR="http://127.0.0.1:8200"
  export VAULT_TOKEN

  vault token lookup >/dev/null

  if ! vault secrets list -format=json | grep -q "\"kv/\""; then
    vault secrets enable -path=kv kv-v2 >/dev/null
  fi

  if ! vault auth list -format=json | grep -q "\"kubernetes/\""; then
    vault auth enable -path=kubernetes kubernetes >/dev/null
  fi

  vault write auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc:443" >/dev/null

  vault policy write cloudflared-read - >/dev/null <<POLICY
path "kv/data/homeserver/cloudflared" {
  capabilities = ["read"]
}

path "kv/metadata/homeserver/cloudflared" {
  capabilities = ["read"]
}
POLICY

  vault write auth/kubernetes/role/cloudflared \
    bound_service_account_names=cloudflared-vault-auth \
    bound_service_account_namespaces=cloudflared \
    audience=vault \
    policies=cloudflared-read \
    ttl=1h >/dev/null

  printf "%s" "$TUNNEL_TOKEN" | \
    vault kv put -mount=kv homeserver/cloudflared token=- >/dev/null

  unset VAULT_TOKEN TUNNEL_TOKEN
'

unset ROOT_TOKEN TUNNEL_TOKEN

log "Waiting for External Secrets to create cloudflared-token"
kubectl wait --for=create secretstore/vault-backend -n cloudflared \
  --timeout="$WAIT_TIMEOUT"
kubectl wait --for=create externalsecret/cloudflared-token -n cloudflared \
  --timeout="$WAIT_TIMEOUT"
kubectl annotate externalsecret cloudflared-token -n cloudflared \
  external-secrets.io/force-sync="$(date +%s)" --overwrite
kubectl wait secretstore/vault-backend -n cloudflared \
  --for=condition=Ready --timeout="$WAIT_TIMEOUT"
kubectl wait externalsecret/cloudflared-token -n cloudflared \
  --for=condition=Ready --timeout="$WAIT_TIMEOUT"
kubectl rollout status deployment/cloudflared -n cloudflared --timeout="$WAIT_TIMEOUT"

log "Vault and the Cloudflare tunnel secret are ready"
