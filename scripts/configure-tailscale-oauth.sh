#!/usr/bin/env bash

set -Eeuo pipefail

readonly VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
readonly VAULT_POD="${VAULT_POD:-vault-0}"
readonly VAULT_ADDR="http://127.0.0.1:8200"
readonly TAILSCALE_NAMESPACE="${TAILSCALE_NAMESPACE:-tailscale}"
readonly TAILSCALE_CONNECTOR="${TAILSCALE_CONNECTOR:-homeserver}"
readonly WAIT_TIMEOUT="${VAULT_WAIT_TIMEOUT:-300s}"

ROOT_TOKEN=""
TAILSCALE_CLIENT_ID=""
TAILSCALE_CLIENT_SECRET=""

cleanup() {
  unset ROOT_TOKEN TAILSCALE_CLIENT_ID TAILSCALE_CLIENT_SECRET
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

for command_name in kubectl jq; do
  require_command "$command_name"
done

log "Waiting for the Vault pod"
kubectl get pod "$VAULT_POD" -n "$VAULT_NAMESPACE" >/dev/null \
  || fail "Vault is not deployed; run deploy.sh first"
kubectl wait pod/"$VAULT_POD" -n "$VAULT_NAMESPACE" \
  --for=jsonpath='{.status.phase}'=Running --timeout="$WAIT_TIMEOUT"

status="$(vault_status)"
[[ "$(jq -r '.initialized' <<<"$status")" == "true" ]] \
  || fail "Vault is not initialized; run scripts/bootstrap-vault.sh first"
[[ "$(jq -r '.sealed' <<<"$status")" == "false" ]] \
  || fail "Vault is sealed; run scripts/unseal-vault.sh first"

read -r -s -p "Vault root token: " ROOT_TOKEN
printf '\n'
[[ -n "$ROOT_TOKEN" ]] || fail "Vault root token cannot be empty"

read -r -p "Tailscale OAuth client ID: " TAILSCALE_CLIENT_ID
[[ -n "$TAILSCALE_CLIENT_ID" ]] || fail "Tailscale OAuth client ID cannot be empty"

read -r -s -p "Tailscale OAuth client secret: " TAILSCALE_CLIENT_SECRET
printf '\n'
[[ -n "$TAILSCALE_CLIENT_SECRET" ]] \
  || fail "Tailscale OAuth client secret cannot be empty"

log "Configuring the Vault policy, Kubernetes auth role, and Tailscale credentials"
{
  printf '%s\n' "$ROOT_TOKEN"
  printf '%s\n' "$TAILSCALE_CLIENT_ID"
  printf '%s\n' "$TAILSCALE_CLIENT_SECRET"
} | kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh -ec '
  IFS= read -r VAULT_TOKEN
  IFS= read -r TAILSCALE_CLIENT_ID
  IFS= read -r TAILSCALE_CLIENT_SECRET
  export VAULT_ADDR="http://127.0.0.1:8200"
  export VAULT_TOKEN

  vault token lookup >/dev/null
  vault secrets list -format=json | grep -q "\"kv/\"" \
    || { printf "KV v2 is not enabled at kv/\n" >&2; exit 1; }
  vault auth list -format=json | grep -q "\"kubernetes/\"" \
    || { printf "Kubernetes auth is not enabled at kubernetes/\n" >&2; exit 1; }

  vault policy write tailscale-oauth-read - >/dev/null <<POLICY
path "kv/data/homeserver/tailscale" {
  capabilities = ["read"]
}

path "kv/metadata/homeserver/tailscale" {
  capabilities = ["read"]
}
POLICY

  vault write auth/kubernetes/role/tailscale \
    bound_service_account_names=tailscale-vault-auth \
    bound_service_account_namespaces=tailscale \
    audience=vault \
    policies=tailscale-oauth-read \
    ttl=1h >/dev/null

  printf "%s" "$TAILSCALE_CLIENT_ID" | \
    vault kv put -mount=kv homeserver/tailscale clientId=- >/dev/null
  printf "%s" "$TAILSCALE_CLIENT_SECRET" | \
    vault kv patch -mount=kv homeserver/tailscale clientSecret=- >/dev/null

  unset VAULT_TOKEN TAILSCALE_CLIENT_ID TAILSCALE_CLIENT_SECRET
'

unset ROOT_TOKEN TAILSCALE_CLIENT_ID TAILSCALE_CLIENT_SECRET

log "Waiting for External Secrets to create operator-oauth"
kubectl wait --for=create secretstore/vault-backend -n "$TAILSCALE_NAMESPACE" \
  --timeout="$WAIT_TIMEOUT"
kubectl wait --for=create externalsecret/operator-oauth -n "$TAILSCALE_NAMESPACE" \
  --timeout="$WAIT_TIMEOUT"
kubectl annotate externalsecret operator-oauth -n "$TAILSCALE_NAMESPACE" \
  external-secrets.io/force-sync="$(date +%s)" --overwrite
kubectl wait secretstore/vault-backend -n "$TAILSCALE_NAMESPACE" \
  --for=condition=Ready --timeout="$WAIT_TIMEOUT"
kubectl wait externalsecret/operator-oauth -n "$TAILSCALE_NAMESPACE" \
  --for=condition=Ready --timeout="$WAIT_TIMEOUT"

log "Waiting for the Tailscale operator and subnet connector"
kubectl rollout status deployment/operator -n "$TAILSCALE_NAMESPACE" \
  --timeout="$WAIT_TIMEOUT"
kubectl wait connector/"$TAILSCALE_CONNECTOR" \
  --for=condition=ConnectorReady --timeout="$WAIT_TIMEOUT"

log "Tailscale operator and connector are ready"
kubectl get connector "$TAILSCALE_CONNECTOR"
printf '\nApprove the advertised subnet routes in the Tailscale admin console if they are not auto-approved.\n'
