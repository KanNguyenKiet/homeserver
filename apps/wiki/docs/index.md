# Homeserver Wiki

A single-node homelab on **k3s**, managed entirely through **GitOps**. This wiki
explains why I built it this way and how the pieces fit together.

!!! info "How to read this wiki"
    **https://wiki.huukiet.com** is the main documentation for this homelab.

    The [repository README](https://github.com/KanNguyenKiet/homeserver/blob/master/README.md)
    only covers bootstrap and `deploy.sh`.
## At a glance

| Layer | What runs there |
| --- | --- |
| Host | Ubuntu, k3s, PostgreSQL 16, ZFS photo storage |
| Platform | Argo CD, Vault, External Secrets, ingress-nginx, cloudflared, Tailscale |
| Apps | Gitea, Immich, Homepage, Wiki |

Content is versioned in Git under `apps/wiki/docs/`. After you push to `master`, Gitea
Actions builds the container image, tags it with the commit SHA, updates
`apps/wiki/values.yaml`, and Argo CD syncs the new tag.
