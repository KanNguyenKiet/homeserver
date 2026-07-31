# Homeserver GitOps

Argo CD **app-of-apps** GitOps for a k3s homelab. Git is the desired state; the cluster
syncs platforms and applications from this repository.

## Documentation

**https://wiki.huukiet.com**

Architecture, components, secrets, networking, tradeoffs, and the build journey are
documented there. Wiki source lives in `apps/wiki/docs/` and deploys with the wiki app.

## Quick start

**First-time cluster bootstrap** (after pushing to `master`):

```bash
kubectl apply -k platforms/argocd
kubectl wait --for=condition=Available deployment/argocd-server \
  -n argocd --timeout=5m
kubectl apply -f root-application.yaml
```

**Deploy on the homeserver** (requires `git`, `helm`, `kubectl`; Vault ops also need `jq`):

```bash
git pull --ff-only origin master
bash deploy.sh
```

The script deploys the checked-out `master` commit, validates Helm charts, applies the
root Application, and waits for child Applications to sync. Pull before running; it
refuses dirty working trees.

Optional timeout override:

```bash
DEPLOY_TIMEOUT_SECONDS=900 bash deploy.sh
```

## Layout

```text
homeserver/
|-- apps/           # Workloads (Gitea, wiki, homepage, …)
|-- platforms/      # Cluster services (Argo CD config, Vault, ingress, monitoring, …)
|-- scripts/        # Vault bootstrap, unseal, vaultsecret CLI
|-- kustomization.yaml
`-- root-application.yaml
```

See the wiki [Architecture](https://wiki.huukiet.com/architecture/) page for how the
pieces connect.

## Related

| Resource | Location |
| --- | --- |
| Wiki site | https://wiki.huukiet.com |
| `vaultsecret` CLI | [scripts/vaultsecret/README.md](scripts/vaultsecret/README.md) |
| Local wiki preview | `cd apps/wiki && mkdocs serve` |
