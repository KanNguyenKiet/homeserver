# Secret management

No credentials are committed to Git. Vault is initialized once with Shamir unseal
keys (3 shares, threshold 2). After every Vault pod restart, an operator must unseal
it manually.

## Flow

```text
  Operator                    Vault                    Cluster
     |                          |                         |
     |  vaultsecret CLI         |                         |
     |  (via kubectl exec) ---->|  kv/homeserver/*        |
     |                          |                         |
     |                          |<---- K8s auth ----------|
     |                          |      (SA token)         |
     |                          |                         |
     |                          |---- External Secrets -->| K8s Secret
     |                          |                         |
     |                          |                         v
     |                          |                    App Deployment
```

The `vaultsecret` Go CLI writes secrets to Vault, creates a read-only policy and
Kubernetes auth role bound to one ServiceAccount, then waits for External Secrets to
sync. It is used for Cloudflare tunnel tokens, Gitea database credentials, Argo CD
GitHub OAuth, and Tailscale OAuth.

!!! warning "Recovery material"
    Vault recovery material (root token and unseal keys) is stored offline only.
    It never lives in Git or inside the cluster.

See [scripts/vaultsecret/README.md](https://github.com/KanNguyenKiet/homeserver/blob/master/scripts/vaultsecret/README.md)
for the full CLI reference.
