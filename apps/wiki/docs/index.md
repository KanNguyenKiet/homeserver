# Homeserver Wiki

A single-node homelab on **k3s**, managed entirely through **GitOps**. This wiki
explains why I built it this way and how the pieces fit together.

!!! info "How to read this wiki"
    This is the architectural summary. The [repository README](https://github.com/KanNguyenKiet/homeserver/blob/master/README.md)
    is the operator manual with full commands and runbooks.

## At a glance

| Layer | What runs there |
| --- | --- |
| Host | Ubuntu, k3s, PostgreSQL 16 |
| Platform | Argo CD, Vault, External Secrets, ingress-nginx, cloudflared, Tailscale |
| Apps | Gitea, Homepage, Wiki |

Content is versioned in Git under `apps/wiki/docs/`. After you push to `master`, run
`bash deploy.sh` on the server to build the container image, push it to the Gitea
registry, and sync through Argo CD.
