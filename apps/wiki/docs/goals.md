# Design goals

I wanted a home server that behaves like a small production platform: declarative
configuration, automatic reconciliation, and no manual `kubectl apply` for day-to-day
changes. Everything lives in a public Git repository; Argo CD keeps the cluster in
sync with that repo.

## GitOps first

Git is the source of truth. Merge to `master`, Argo CD syncs.

## No secrets in Git

Vault holds credentials. External Secrets materializes them in-cluster.

## Minimal host footprint

k3s runs all application workloads, including per-app PostgreSQL instances. The
host only provides the cluster runtime and node-local storage.

## Remote access without port forwarding

Cloudflare Tunnel for public HTTPS. Tailscale for private LAN and cluster access.
