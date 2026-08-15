#!/usr/bin/env bash
# TEMPORARY: migrate from per-app Vault roles to cluster-secrets.
# Safe to delete after migration completes on every cluster.
#
# What it does:
#   1. Ensures registry creds live at kv/homeserver/registry (copies from
#      kv/homeserver/wiki when needed).
#   2. Creates the cluster-secrets-read policy (read all kv/homeserver/*).
#   3. Creates the cluster-secrets Kubernetes auth role.
#   4. Force-syncs the ExternalSecrets managed by ClusterExternalSecret.
#
# Usage (on the homeserver, after Argo CD syncs cluster-secrets):
#   export VAULT_ROOT_TOKEN="$(jq -r .root_token /var/lib/vault-bootstrap/vault-init.json)"
#   bash scripts/migrate-cluster-secrets.sh
#   bash scripts/migrate-cluster-secrets.sh -dry-run

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"

readonly VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
readonly VAULT_POD="${VAULT_POD:-vault-0}"
readonly VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
readonly VAULT_MOUNT="${VAULT_MOUNT:-kv}"
readonly VAULT_INIT_OUTPUT="${VAULT_INIT_OUTPUT:-/var/lib/vault-bootstrap/vault-init.json}"
readonly WAIT_TIMEOUT="${WAIT_TIMEOUT:-300s}"

readonly POLICY_NAME="${POLICY_NAME:-cluster-secrets-read}"
readonly ROLE_NAME="${ROLE_NAME:-cluster-secrets}"
readonly BOUND_SA="${BOUND_SA:-cluster-secrets-vault-auth}"
readonly BOUND_NAMESPACE="${BOUND_NAMESPACE:-external-secrets}"
readonly AUDIENCE="${AUDIENCE:-vault}"
readonly ROLE_TTL="${ROLE_TTL:-24h}"
readonly CLUSTER_SECRET_STORE="${CLUSTER_SECRET_STORE:-homeserver-vault}"

readonly REGISTRY_VAULT_PATH="homeserver/registry"
readonly WIKI_VAULT_PATH="homeserver/wiki"

readonly -a MANAGED_SECRETS=(
  gitea-secret
  gitea-actions-token
  gitea-registry
  grafana-admin
  cloudflared-token
  operator-oauth
  argocd-github-oauth
)

DRY_RUN=false

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

parse_args() {
  while (($#)); do
    case "$1" in
      -dry-run)
        DRY_RUN=true
        ;;
      -h | --help)
        sed -n '1,20p' "$0"
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

resolve_root_token() {
  if [[ -n "${VAULT_ROOT_TOKEN:-}" ]]; then
    return 0
  fi
  [[ -f "$VAULT_INIT_OUTPUT" ]] \
    || fail "Set VAULT_ROOT_TOKEN or point VAULT_INIT_OUTPUT at vault-init.json"
  VAULT_ROOT_TOKEN="$(jq -er .root_token "$VAULT_INIT_OUTPUT")" \
    || fail "Could not read root_token from $VAULT_INIT_OUTPUT"
  export VAULT_ROOT_TOKEN
}

vault_json() {
  local subcommand=$1
  shift
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    env VAULT_ADDR="$VAULT_ADDR" VAULT_TOKEN="$VAULT_ROOT_TOKEN" \
    vault "$subcommand" -format=json "$@"
}

vault_shell() {
  local script=$1
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] would run Vault script:\n%s\n' "$script"
    return 0
  fi
  kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh -ec "$script" <<<"$VAULT_ROOT_TOKEN"
}

require_vault_ready() {
  require_command kubectl
  require_command jq
  kubectl get pod "$VAULT_POD" -n "$VAULT_NAMESPACE" >/dev/null 2>&1 \
    || fail "Vault pod $VAULT_NAMESPACE/$VAULT_POD not found"
  kubectl wait pod/"$VAULT_POD" -n "$VAULT_NAMESPACE" \
    --for=condition=Ready --timeout="$WAIT_TIMEOUT"

  local status initialized sealed
  status="$(vault_json status)"
  initialized="$(jq -er .initialized <<<"$status")"
  sealed="$(jq -er .sealed <<<"$status")"
  [[ "$initialized" == true ]] || fail "Vault is not initialized"
  [[ "$sealed" == false ]] || fail "Vault is sealed; run scripts/unseal-vault.sh first"
}

kv_field() {
  local path=$1
  local field=$2
  local json

  if ! json="$(vault_json kv get -mount="$VAULT_MOUNT" "$path" 2>/dev/null)"; then
    return 1
  fi
  jq -er --arg field "$field" '.data.data[$field] // empty' <<<"$json"
}

kv_has_field() {
  local path=$1
  local field=$2
  kv_field "$path" "$field" >/dev/null 2>&1
}

migrate_registry_path() {
  log "Checking registry credentials at $VAULT_MOUNT/$REGISTRY_VAULT_PATH"

  if kv_has_field "$REGISTRY_VAULT_PATH" registryUsername \
    && kv_has_field "$REGISTRY_VAULT_PATH" registryPassword; then
    printf 'Registry credentials already present at %s/%s\n' "$VAULT_MOUNT" "$REGISTRY_VAULT_PATH"
    return 0
  fi

  local username password
  username="$(kv_field "$WIKI_VAULT_PATH" registryUsername 2>/dev/null || true)"
  password="$(kv_field "$WIKI_VAULT_PATH" registryPassword 2>/dev/null || true)"

  if [[ -z "$username" || -z "$password" ]]; then
    fail "Missing registry creds at $REGISTRY_VAULT_PATH and $WIKI_VAULT_PATH"
  fi

  printf 'Copying registryUsername/registryPassword from %s to %s\n' \
    "$WIKI_VAULT_PATH" "$REGISTRY_VAULT_PATH"

  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] would patch %s/%s with registryUsername + registryPassword\n' \
      "$VAULT_MOUNT" "$REGISTRY_VAULT_PATH"
    return 0
  fi

  local script
  script="$(cat <<EOF
IFS= read -r VAULT_TOKEN
IFS= read -r REGISTRY_USERNAME
IFS= read -r REGISTRY_PASSWORD
export VAULT_ADDR=$VAULT_ADDR
export VAULT_TOKEN
vault kv patch -mount=$VAULT_MOUNT $REGISTRY_VAULT_PATH \
  registryUsername="\$REGISTRY_USERNAME" \
  registryPassword="\$REGISTRY_PASSWORD" >/dev/null
unset VAULT_TOKEN REGISTRY_USERNAME REGISTRY_PASSWORD
EOF
)"
  kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh -ec "$script" <<EOF
$VAULT_ROOT_TOKEN
$username
$password
EOF
}

write_cluster_policy_and_role() {
  log "Writing policy $POLICY_NAME and Kubernetes auth role $ROLE_NAME"

  local script
  script="$(cat <<EOF
IFS= read -r VAULT_TOKEN
export VAULT_ADDR=$VAULT_ADDR
export VAULT_TOKEN
vault token lookup >/dev/null
vault policy write $POLICY_NAME - >/dev/null <<'POLICY'
path "$VAULT_MOUNT/data/homeserver/*" {
  capabilities = ["read"]
}

path "$VAULT_MOUNT/metadata/homeserver/*" {
  capabilities = ["read"]
}
POLICY
vault write auth/kubernetes/role/$ROLE_NAME \
  bound_service_account_names=$BOUND_SA \
  bound_service_account_namespaces=$BOUND_NAMESPACE \
  audience=$AUDIENCE \
  policies=$POLICY_NAME \
  ttl=$ROLE_TTL >/dev/null
unset VAULT_TOKEN
EOF
)"
  vault_shell "$script"
}

wait_for_cluster_secret_store() {
  log "Waiting for ClusterSecretStore/$CLUSTER_SECRET_STORE"
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] would wait for ClusterSecretStore/%s\n' "$CLUSTER_SECRET_STORE"
    return 0
  fi
  kubectl wait clustersecretstore/"$CLUSTER_SECRET_STORE" \
    --for=condition=Ready --timeout="$WAIT_TIMEOUT"
}

force_sync_managed_externalsecrets() {
  log "Force-syncing managed ExternalSecrets"
  local ts name namespace line
  ts="$(date +%s)"

  for name in "${MANAGED_SECRETS[@]}"; do
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      namespace="${line%%/*}"
      if [[ "$DRY_RUN" == true ]]; then
        printf '[dry-run] would annotate externalsecret/%s -n %s\n' "$name" "$namespace"
        continue
      fi
      kubectl annotate externalsecret "$name" -n "$namespace" \
        "external-secrets.io/force-sync=$ts" --overwrite >/dev/null
      kubectl wait externalsecret/"$name" -n "$namespace" \
        --for=condition=Ready --timeout="$WAIT_TIMEOUT"
      printf 'Synced externalsecret/%s in namespace %s\n' "$name" "$namespace"
    done < <(
      kubectl get externalsecret -A --no-headers 2>/dev/null \
        | awk -v name="$name" '$2 == name { print $1 "/" $2 }' || true
    )
  done
}

print_summary() {
  log "Migration complete"
  cat <<EOF
Next checks:
  kubectl get clustersecretstore $CLUSTER_SECRET_STORE
  kubectl get clusterexternalsecret
  kubectl get externalsecret -A | rg 'gitea-secret|gitea-registry|grafana-admin|cloudflared-token|operator-oauth|argocd-github-oauth'

You can delete scripts/migrate-cluster-secrets.sh after every cluster is migrated.
EOF
}

main() {
  parse_args "$@"
  require_command kubectl
  require_command jq
  resolve_root_token
  require_vault_ready
  migrate_registry_path
  write_cluster_policy_and_role
  wait_for_cluster_secret_store
  force_sync_managed_externalsecrets
  print_summary
}

main "$@"
