#!/usr/bin/env bash

set -Eeuo pipefail

readonly VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
readonly VAULT_POD="${VAULT_POD:-vault-0}"
readonly VAULT_ADDR="http://127.0.0.1:8200"
readonly WAIT_TIMEOUT="${VAULT_WAIT_TIMEOUT:-300s}"

readonly DB_NAME="${GITEA_DB_NAME:-gitea}"
readonly DB_USER="${GITEA_DB_USER:-gitea}"

ROOT_TOKEN=""
DB_PASSWORD=""

cleanup() {
  unset ROOT_TOKEN DB_PASSWORD
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

validate_identifier() {
  [[ "$1" =~ ^[a-z_][a-z0-9_]*$ ]] \
    || fail "$2 must match ^[a-z_][a-z0-9_]*$: $1"
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

for command_name in kubectl jq sudo psql; do
  require_command "$command_name"
done

validate_identifier "$DB_NAME" "GITEA_DB_NAME"
validate_identifier "$DB_USER" "GITEA_DB_USER"

read -r -s -p "Gitea PostgreSQL password: " DB_PASSWORD
printf '\n'
[[ -n "$DB_PASSWORD" ]] || fail "Gitea PostgreSQL password cannot be empty"

log "Creating or updating the PostgreSQL role and database"
sudo -u postgres psql \
  --set ON_ERROR_STOP=1 \
  --set db_name="$DB_NAME" \
  --set db_user="$DB_USER" \
  --set db_password="$DB_PASSWORD" <<'SQL'
SELECT format(
  'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
  :'db_user'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'db_user'
)\gexec

ALTER ROLE :"db_user" WITH PASSWORD :'db_password';

SELECT format(
  'CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING ''UTF8''',
  :'db_name',
  :'db_user'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = :'db_name'
)\gexec

REVOKE ALL ON DATABASE :"db_name" FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE :"db_name" TO :"db_user";
SQL

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

log "Writing the Gitea database credentials to Vault"
{
  printf '%s\n' "$ROOT_TOKEN"
  printf '%s\n' "$DB_NAME"
  printf '%s\n' "$DB_USER"
  printf '%s\n' "$DB_PASSWORD"
} | kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh -ec '
  IFS= read -r VAULT_TOKEN
  IFS= read -r DB_NAME
  IFS= read -r DB_USER
  IFS= read -r DB_PASSWORD
  export VAULT_ADDR="http://127.0.0.1:8200"
  export VAULT_TOKEN

  vault token lookup >/dev/null
  vault secrets list -format=json | grep -q "\"kv/\"" \
    || { printf "KV v2 is not enabled at kv/\n" >&2; exit 1; }
  vault auth list -format=json | grep -q "\"kubernetes/\"" \
    || { printf "Kubernetes auth is not enabled at kubernetes/\n" >&2; exit 1; }

  vault policy write gitea-db-read - >/dev/null <<POLICY
path "kv/data/homeserver/gitea" {
  capabilities = ["read"]
}

path "kv/metadata/homeserver/gitea" {
  capabilities = ["read"]
}
POLICY

  vault write auth/kubernetes/role/gitea \
    bound_service_account_names=gitea-vault-auth \
    bound_service_account_namespaces=gitea \
    audience=vault \
    policies=gitea-db-read \
    ttl=1h >/dev/null

  vault kv put -mount=kv homeserver/gitea \
    dbName="$DB_NAME" \
    dbUser="$DB_USER" \
    dbPassword="$DB_PASSWORD" >/dev/null

  unset VAULT_TOKEN DB_NAME DB_USER DB_PASSWORD
'

unset ROOT_TOKEN DB_PASSWORD

log "Waiting for External Secrets to create the Gitea database Secret"
kubectl wait --for=create secretstore/vault-backend -n gitea \
  --timeout="$WAIT_TIMEOUT"
kubectl wait --for=create externalsecret/gitea-secret -n gitea \
  --timeout="$WAIT_TIMEOUT"
kubectl annotate externalsecret gitea-secret -n gitea \
  external-secrets.io/force-sync="$(date +%s)" --overwrite
kubectl wait secretstore/vault-backend -n gitea \
  --for=condition=Ready --timeout="$WAIT_TIMEOUT"
kubectl wait externalsecret/gitea-secret -n gitea \
  --for=condition=Ready --timeout="$WAIT_TIMEOUT"

log "Gitea PostgreSQL credentials are ready"
