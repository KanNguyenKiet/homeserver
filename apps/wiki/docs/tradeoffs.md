# Intentional tradeoffs

- **Single node, no HA.** Vault runs one Raft member. A server reboot means manual
  unseal and brief downtime.

- **Native PostgreSQL.** Simpler backups and upgrades, but Gitea and Immich depend
  on host availability outside k8s. Immich requires **VectorChord** on the same
  instance; PostgreSQL restarts and extension upgrades affect both apps.

- **Immich library on local-path.** The 200Gi library PVC uses k3s `local-path`,
  which does not support online expansion. Growing storage means migrating to a new
  PVC or mount, not only editing `size` in Git.

- **Public Git repo.** Argo CD pulls over HTTPS without credentials. Making the repo
  private requires adding a repository secret.

- **Cloudflare TLS termination.** Traffic between Cloudflare and the cluster is
  encrypted by the tunnel, but origin certificates are not publicly trusted.

- **MkDocs wiki.** Content changes require a Git commit; Gitea Actions builds the
  image, commits the SHA tag to `values.yaml`, and Argo CD syncs — not in-browser
  editing. That matches the GitOps model.
