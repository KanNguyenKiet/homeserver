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

**Normal GitOps deploy**:

```bash
git push origin master
```

After the first bootstrap, Argo CD watches `master` and syncs the root Application
and child Applications from Git. To force a refresh from the cluster:

```bash
kubectl annotate application homeserver -n argocd \
  argocd.argoproj.io/refresh=hard --overwrite
```

## Layout

```text
homeserver/
|-- apps/           # Workloads (Gitea, Woodpecker, wiki, homepage, ...)
|-- platforms/      # Cluster services (Argo CD config, Vault, ingress, monitoring, ...)
|-- scripts/        # Vault bootstrap, unseal, vaultsecret CLI
|-- kustomization.yaml
`-- root-application.yaml
```

See the wiki [Architecture](https://wiki.huukiet.com/architecture/) page for how the
pieces connect.

## Woodpecker Terraform CI

Woodpecker runs at `https://ci.huukiet.com`. The infra repo
`https://git.huukiet.com/ops/homeserver_infra.git` owns the Terraform workflow in
`.woodpecker/terraform.yaml`; pushes merged to `master` run Terraform for Vault
configuration after the repo is activated in Woodpecker.

Bootstrap order:

```bash
cd ~/homeserver_infra
kubectl -n vault port-forward svc/vault-ui 8200:8200
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN='<root-or-admin-token>'
kubectl create namespace woodpecker --dry-run=client -o yaml | kubectl apply -f -

scripts/import-vault-state.sh
terraform -chdir=infra/vault apply
```

Create a Gitea OAuth application with callback
`https://ci.huukiet.com/authorize`, then store its client values in Vault:

```bash
scripts/vaultsecret/vaultsecret \
  -path homeserver/woodpecker \
  -set-prompt WOODPECKER_GITEA_CLIENT \
  -set-prompt WOODPECKER_GITEA_SECRET
```

Push this repo to `master`, wait for Argo CD to sync Woodpecker, then log in at
`https://ci.huukiet.com` and activate `ops/homeserver_infra`. If Gitea webhook
delivery is blocked, keep `ALLOWED_HOST_LIST=external,loopback` in the Gitea
webhook config.

## Related

| Resource | Location |
| --- | --- |
| Wiki site | https://wiki.huukiet.com |
| Woodpecker CI | https://ci.huukiet.com |
| `vaultsecret` CLI | [scripts/vaultsecret/README.md](scripts/vaultsecret/README.md) |
| Local wiki preview | `cd apps/wiki && mkdocs serve` |
