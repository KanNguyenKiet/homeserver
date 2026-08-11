# Secret management

No credentials are committed to Git. Vault is initialized once with Shamir unseal
keys (3 shares, threshold 2). After every Vault pod restart, an operator must unseal
it manually.

## Flow

All Vault → Kubernetes secret sync lives in `platforms/cluster-secrets`. One
`ClusterSecretStore` connects to Vault; one `ClusterExternalSecret` exists per
Kubernetes secret. App and platform charts only reference secret names — they never
define `SecretStore` or `ExternalSecret` resources.

```text
  Operator                    Vault                         Cluster
     |                          |                              |
     |  vaultsecret CLI         |                              |
     |  (via kubectl exec) ---->|  kv/homeserver/*             |
     |                          |                              |
     |                          |<---- K8s auth ----------------|
     |                          |      cluster-secrets role    |
     |                          |      (cluster-secrets-       |
     |                          |       vault-auth SA)         |
     |                          |                              |
     |                          |---- External Secrets ------->| K8s Secret
     |                          |                              |
     |                          |                              v
     |                          |                         App Deployment
```

External Secrets authenticates to Vault as the shared Kubernetes auth role
`cluster-secrets`, bound to the `cluster-secrets-vault-auth` ServiceAccount in the
`external-secrets` namespace.

## Synced secrets

| Kubernetes secret | Namespace(s) | Vault path |
| --- | --- | --- |
| `gitea-secret` | `gitea` | `homeserver/gitea` |
| `immich-secret` | `immich` | `homeserver/immich` |
| `gitea-actions-token` | `gitea` | `homeserver/gitea-actions` |
| `gitea-registry` | all non-system | `homeserver/registry` |
| `grafana-admin` | `monitoring` | `homeserver/grafana` |
| `cloudflared-token` | `cloudflared` | `homeserver/cloudflared` |
| `operator-oauth` | `tailscale` | `homeserver/tailscale` |
| `argocd-github-oauth` | `argocd` | `homeserver/argocd` |

## Writing secrets with vaultsecret

The `vaultsecret` Go CLI writes secrets to Vault via `kubectl exec`, then waits for
External Secrets to sync. See
[scripts/vaultsecret/README.md](https://github.com/KanNguyenKiet/homeserver/blob/master/scripts/vaultsecret/README.md)
for the full CLI reference.

### First-time setup (policy + role + secret)

On a fresh cluster, pass the shared role flags so `vaultsecret` creates the
`cluster-secrets-read` policy and `cluster-secrets` Kubernetes auth role:

```bash
export VAULT_ROOT_TOKEN="$(sudo jq -r .root_token /var/lib/vault-bootstrap/vault-init.json)"

scripts/vaultsecret/vaultsecret \
  -path homeserver/argocd \
  -set-prompt githubClientID -set-prompt githubClientSecret \
  -policy cluster-secrets-read -role cluster-secrets \
  -bound-sa cluster-secrets-vault-auth -bound-namespace external-secrets \
  -wait-externalsecret argocd-github-oauth -app-namespace argocd \
  -restart argocd-dex-server -restart argocd-server
```

Every integration uses the same role flags:

```text
-policy cluster-secrets-read -role cluster-secrets \
-bound-sa cluster-secrets-vault-auth -bound-namespace external-secrets
```

### Updating an existing secret

After the shared policy and role exist, write or rotate fields with `-patch` only
and omit `-policy` and `-role`. The `cluster-secrets-read` policy grants read on
all `homeserver/*` paths; as of the `vaultsecret` fix, passing
`-policy cluster-secrets-read` also writes that wildcard instead of narrowing to
one path.

```bash
scripts/vaultsecret/vaultsecret \
  -path homeserver/argocd -patch \
  -set-prompt githubClientID -set-prompt githubClientSecret \
  -wait-externalsecret argocd-github-oauth -app-namespace argocd \
  -restart argocd-dex-server -restart argocd-server
```

!!! warning "Prefer -patch for secret updates"
    After bootstrap, use `-patch` without `-policy` or `-role` when rotating
    credentials. Older `vaultsecret` builds replaced `cluster-secrets-read` with a
    single-path policy and broke other ExternalSecrets with Vault **403 permission
    denied**.

## Vault policy and role

The `cluster-secrets-read` policy must grant read on all homeserver paths:

```hcl
path "kv/data/homeserver/*" {
  capabilities = ["read"]
}

path "kv/metadata/homeserver/*" {
  capabilities = ["read"]
}
```

The `cluster-secrets` Kubernetes auth role binds that policy to
`cluster-secrets-vault-auth` in `external-secrets`.

To create or restore the policy and role manually (without a shell script):

```bash
export VAULT_ROOT_TOKEN="$(sudo jq -r .root_token /var/lib/vault-bootstrap/vault-init.json)"

sudo kubectl exec -n vault vault-0 -- sh -ec "
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$VAULT_ROOT_TOKEN

vault policy write cluster-secrets-read - <<'EOF'
path \"kv/data/homeserver/*\" {
  capabilities = [\"read\"]
}

path \"kv/metadata/homeserver/*\" {
  capabilities = [\"read\"]
}
EOF

vault write auth/kubernetes/role/cluster-secrets \
  bound_service_account_names=cluster-secrets-vault-auth \
  bound_service_account_namespaces=external-secrets \
  audience=vault \
  policies=cluster-secrets-read \
  ttl=24h
"
```

Then force External Secrets to retry:

```bash
sudo kubectl annotate externalsecret argocd-github-oauth -n argocd \
  "external-secrets.io/force-sync=$(date +%s)" --overwrite

sudo kubectl wait externalsecret/argocd-github-oauth -n argocd \
  --for=condition=Ready --timeout=300s
```

## Troubleshooting

### ExternalSecret: 403 permission denied

Symptom (example for Argo CD GitHub OAuth):

```text
error processing spec.data[0] (key: homeserver/argocd), err: cannot read secret
data from Vault: ... Code: 403 ... permission denied
```

**Check the policy** — it may have been narrowed to a single path:

```bash
export VAULT_ROOT_TOKEN="$(sudo jq -r .root_token /var/lib/vault-bootstrap/vault-init.json)"

sudo kubectl exec -n vault vault-0 -- sh -c "
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$VAULT_ROOT_TOKEN
vault policy read cluster-secrets-read
"
```

If you see only one path (e.g. `homeserver/registry`) instead of `homeserver/*`,
restore the wildcard policy using the commands in [Vault policy and role](#vault-policy-and-role)
above.

**Verify the secret exists** (root token can read regardless of the ESO policy):

```bash
sudo kubectl exec -n vault vault-0 -- sh -c "
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$VAULT_ROOT_TOKEN
vault kv get -mount=kv homeserver/argocd
"
```

**Verify sync status:**

```bash
sudo kubectl get clustersecretstore homeserver-vault
sudo kubectl -n argocd get externalsecret argocd-github-oauth -o wide
sudo kubectl -n argocd describe externalsecret argocd-github-oauth
```

After the policy is fixed and the ExternalSecret shows `SecretSynced`, restart
workloads that read the secret at startup (e.g. Argo CD Dex and server).

!!! warning "Recovery material"
    Vault recovery material (root token and unseal keys) is stored offline only.
    It never lives in Git or inside the cluster.
