# Intentional tradeoffs

- **Single node, no HA.** Vault runs one Raft member. A server reboot means manual
  unseal and brief downtime.

- **Per-app PostgreSQL.** Gitea and Immich each run a PostgreSQL 16 StatefulSet in
  their own namespace and node. This isolates restarts and extensions, but the
  `local-path` PVCs remain node-local and are not highly available.

- **Immich library on ZFS (LVM-backed pool).** The library uses a static hostPath PV
  on `homeserver1` at `/tank/immich` (~350Gi). Add capacity by growing the LV or
  pool, not by resizing a `local-path` PVC.

- **Public Git repo.** Argo CD pulls over HTTPS without credentials. Making the repo
  private requires adding a repository secret.

- **Cloudflare TLS termination.** Traffic between Cloudflare and the cluster is
  encrypted by the tunnel, but origin certificates are not publicly trusted.

- **MkDocs wiki.** Content changes require a Git commit; Gitea Actions builds the
  image, commits the SHA tag to `values.yaml`, and Argo CD syncs — not in-browser
  editing. That matches the GitOps model.
