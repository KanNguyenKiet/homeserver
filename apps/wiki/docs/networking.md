# Networking

## Public hostnames (Cloudflare Tunnel)

| Hostname | Service |
| --- | --- |
| `git.huukiet.com` | Gitea |
| `argocd.huukiet.com` | Argo CD (GitHub OAuth via Dex) |
| `home.huukiet.com` | Homepage dashboard |
| `wiki.huukiet.com` | This wiki |

## Private access (Tailscale)

A Tailscale Connector named `homeserver` advertises the LAN (`192.168.1.0/24`), Pod
CIDR (`10.42.0.0/16`), and Service CIDR (`10.43.0.0/16`). Remote tailnet devices
reach the homeserver and cluster internals without exposing ports to the internet.

## Host PostgreSQL

Gitea connects to PostgreSQL running natively on the Ubuntu host. PostgreSQL listens
on localhost and the LAN IP; `pg_hba.conf` allows only the k3s Pod CIDR. This keeps
database backups and upgrades outside the Kubernetes lifecycle.
