# Build journey

The repository is structured as local Helm charts under `platforms/` (cluster
services) and `apps/` (workloads). Wrapper charts pin upstream dependency versions;
configuration lives in `values.yaml` files.

## Steps

1. **Prepare the host** - Install Ubuntu, k3s, PostgreSQL 16, and basic tooling
   (git, helm, kubectl, jq).

2. **Bootstrap Argo CD** - Apply the Argo CD kustomization, then the root
   Application. From here, Git drives everything.

3. **Deploy platform layer** - External Secrets, Vault, ingress-nginx, cloudflared,
   and Tailscale Operator sync via Argo CD.

4. **Initialize Vault** - Run `bootstrap-vault.sh` to init, unseal, enable KV and
   Kubernetes auth, and store the Cloudflare tunnel token.

5. **Wire up secrets** - Deploy `platforms/cluster-secrets`, then use `vaultsecret`
   for Gitea DB creds, Argo CD GitHub OAuth, and Tailscale OAuth. External Secrets
   syncs Vault paths into in-cluster Secrets via the shared `cluster-secrets` role.
   See [Secret management](secrets.md) for the policy footgun and troubleshooting.

6. **Deploy applications** - Gitea, Homepage, and Wiki. Configure Cloudflare Tunnel
   hostname routes pointing to each Service.

7. **Day-two operations** - Push to `master` and let Argo CD auto-sync. Unseal Vault
   after restarts. See [Secret management](secrets.md) for Vault and External
   Secrets operations.
