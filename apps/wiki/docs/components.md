# Components

| Component | Role | Namespace |
| --- | --- | --- |
| **Argo CD** | GitOps controller; app-of-apps entry point | `argocd` |
| **HashiCorp Vault** | Secret store (KV v2, single Raft node) | `vault` |
| **External Secrets** | Syncs Vault paths into Kubernetes Secrets | `external-secrets` |
| **ingress-nginx** | In-cluster HTTP routing and Ingress controller | `ingress-nginx` |
| **cloudflared** | Cloudflare Tunnel connector (2 replicas) | `cloudflared` |
| **Tailscale Operator** | Subnet router for LAN, Pod, and Service CIDRs | `tailscale` |
| **Gitea** | Self-hosted Git forge | `gitea` |
| **Woodpecker CI** | Runs Terraform workflows from the infra repo | `woodpecker` |
| **Immich** | Photo and video backup | `immich` |
| **Valkey** | Immich job queue and cache | `immich` |
| **Homepage** | Service dashboard at `home.huukiet.com` | `homepage` |
| **Wiki** | This documentation site (MkDocs Material) | `wiki` |
| **PostgreSQL 16** | Separate native clusters for Gitea and Immich | - |
| **ZFS** | Retained Immich photo library at `/tank/immich` | - |
