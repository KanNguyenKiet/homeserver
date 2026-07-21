#!/usr/bin/env bash

set -Eeuo pipefail

readonly REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GIT_BRANCH="master"
readonly DEPLOY_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-600}"
readonly KUBECTL_TIMEOUT="${DEPLOY_TIMEOUT_SECONDS}s"

readonly CHARTS=(
  "platforms/external-secrets"
  "platforms/vault"
  "platforms/nginx-ingress"
  "platforms/cloudflared"
  "platforms/tailscale"
  "apps/gitea"
  "apps/homepage"
  "apps/wiki"
)

readonly RELEASES=(
  "external-secrets"
  "vault"
  "ingress-nginx"
  "cloudflared"
  "tailscale"
  "gitea"
  "homepage"
  "wiki"
)

readonly NAMESPACES=(
  "external-secrets"
  "vault"
  "ingress-nginx"
  "cloudflared"
  "tailscale"
  "gitea"
  "homepage"
  "wiki"
)

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

application_revision() {
  kubectl get application "$1" -n argocd \
    -o jsonpath='{.status.sync.revision}' 2>/dev/null || true
}

application_sync_status() {
  kubectl get application "$1" -n argocd \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true
}

wait_for_application() {
  local application="$1"
  local expected_revision="$2"
  local deadline=$((SECONDS + DEPLOY_TIMEOUT_SECONDS))
  local revision
  local sync_status

  while ((SECONDS < deadline)); do
    revision="$(application_revision "$application")"
    sync_status="$(application_sync_status "$application")"

    if [[ "$revision" == "$expected_revision" && "$sync_status" == "Synced" ]]; then
      printf 'Application %s is Synced at %s\n' "$application" "$expected_revision"
      return 0
    fi

    printf 'Waiting for %s (revision=%s, sync=%s)\n' \
      "$application" "${revision:-unknown}" "${sync_status:-unknown}"
    sleep 5
  done

  kubectl get application "$application" -n argocd -o wide || true
  fail "Timed out waiting for Application $application"
}

cd "$REPO_DIR"

for command_name in git helm kubectl; do
  require_command "$command_name"
done

[[ -d .git ]] || fail "$REPO_DIR is not a Git repository"
[[ "$DEPLOY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] \
  || fail "DEPLOY_TIMEOUT_SECONDS must be an integer"

current_branch="$(git branch --show-current)"
[[ "$current_branch" == "$GIT_BRANCH" ]] \
  || fail "Expected branch $GIT_BRANCH, currently on ${current_branch:-detached HEAD}"

if [[ -n "$(git status --porcelain)" ]]; then
  git status --short
  fail "Working tree is not clean; commit or discard local changes before deploying"
fi

readonly EXPECTED_REVISION="$(git rev-parse HEAD)"

log "Deploying commit $EXPECTED_REVISION from local $GIT_BRANCH"

log "Updating Helm dependencies"
helm dependency update platforms/external-secrets
helm dependency update platforms/vault
helm dependency update platforms/nginx-ingress
helm dependency update platforms/tailscale

log "Linting and rendering Helm charts"
render_dir="$(mktemp -d)"
trap 'rm -rf -- "$render_dir"' EXIT

for index in "${!CHARTS[@]}"; do
  chart="${CHARTS[$index]}"
  release="${RELEASES[$index]}"
  namespace="${NAMESPACES[$index]}"

  helm lint "$chart" --strict
  helm template "$release" "$chart" \
    --namespace "$namespace" \
    >"$render_dir/$release.yaml"
done

log "Checking access to the Kubernetes cluster"
kubectl cluster-info >/dev/null

log "Bootstrapping or updating Argo CD"
kubectl apply --server-side --force-conflicts \
  --field-manager=homeserver-deploy \
  -k platforms/argocd
kubectl rollout status deployment/argocd-server \
  -n argocd --timeout="$KUBECTL_TIMEOUT"
kubectl rollout status deployment/argocd-repo-server \
  -n argocd --timeout="$KUBECTL_TIMEOUT"
kubectl rollout status statefulset/argocd-application-controller \
  -n argocd --timeout="$KUBECTL_TIMEOUT"

log "Applying the root Application"
kubectl apply --server-side --force-conflicts \
  --field-manager=homeserver-deploy \
  -f root-application.yaml
kubectl annotate application homeserver -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

log "Waiting for the root Application"
wait_for_application homeserver "$EXPECTED_REVISION"

log "Refreshing child Applications"
kubectl annotate applications.argoproj.io --all -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite

for application in argocd-config external-secrets vault nginx-ingress cloudflared tailscale gitea homepage wiki; do
  wait_for_application "$application" "$EXPECTED_REVISION"
done

log "Deployment completed"
kubectl get applications -n argocd
kubectl get pods -A
