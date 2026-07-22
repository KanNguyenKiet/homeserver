# Intentional tradeoffs

- **Single node, no HA.** Vault runs one Raft member. A server reboot means manual
  unseal and brief downtime.

- **Native PostgreSQL.** Simpler backups and upgrades, but Gitea depends on host
  availability outside k8s.

- **Public Git repo.** Argo CD pulls over HTTPS without credentials. Making the repo
  private requires adding a repository secret.

- **Cloudflare TLS termination.** Traffic between Cloudflare and the cluster is
  encrypted by the tunnel, but origin certificates are not publicly trusted.

- **MkDocs wiki.** Content changes require a Git commit, a container image rebuild via
  GitHub Actions, and an Argo CD sync — not in-browser editing. That matches the
  GitOps model.
