# Homeserver GitOps

This repository uses Argo CD with the app-of-apps pattern. After the initial
bootstrap, Argo CD treats Git as the desired state and automatically synchronizes
platforms and applications to the cluster.

## Structure

```text
homeserver/
|-- apps/                            # Local Helm charts for workloads
|-- platforms/                       # Cluster services
|   |-- argocd/
|   |   `-- config/                  # Argo CD configuration managed through GitOps
|   |-- cloudflared/                 # Cloudflare Tunnel connector Helm chart
|   |-- external-secrets/            # External Secrets wrapper Helm chart
|   |-- nginx-ingress/               # ingress-nginx wrapper Helm chart
|   `-- vault/                       # HashiCorp Vault wrapper Helm chart
|-- scripts/                         # Vault bootstrap and unseal operations
|-- kustomization.yaml               # Root and child Application resources
|-- root-application.yaml            # GitOps entry point
`-- README.md
```

## Initial bootstrap

Push the changes to the `master` branch first, then run:

```bash
kubectl apply -k platforms/argocd
kubectl wait --for=condition=Available deployment/argocd-server \
  -n argocd --timeout=5m
kubectl apply -f root-application.yaml
```

## Server deployment script

After cloning the repository on the home server, deploy the current `master` branch
with:

```bash
git pull --ff-only origin master
bash deploy.sh
```

The script requires `git`, `helm`, and `kubectl`. Vault operations additionally require
`jq`. The script refuses to run with local changes,
deploys the currently checked-out local `master` commit, builds and validates every
Helm chart, updates Argo CD, applies the root Application, and waits for all child
Applications to sync to that commit. Pull changes manually before running the script.

The timeout can be overridden when necessary. Deployment always uses the `master`
branch because the Argo CD Applications track that branch:

```bash
DEPLOY_TIMEOUT_SECONDS=900 bash deploy.sh
```

After this step, there is no need to run `helm install` or `kubectl apply` for each
application. Make changes through Git commits; Argo CD handles synchronization,
pruning, and self-healing.

Child Applications use resource finalizers. Removing an Application from
`kustomization.yaml` will therefore also delete the Kubernetes resources managed by
that Application. Carefully review this type of change before merging it.

## Helm charts

External Secrets, HashiCorp Vault, and ingress-nginx are local wrapper Helm charts in
`platforms/`. Each chart keeps its `application.yaml` beside `Chart.yaml`. The upstream
chart is declared as a dependency in `Chart.yaml` and downloaded during the dependency
build. Generated `Chart.lock` and `charts/*.tgz` files are ignored and are not committed.

Cloudflared, Gitea, and Homepage are local Helm charts. Argo CD renders these charts
directly from Git. Each application's configuration is stored in its corresponding
`values.yaml` file.

- To change a platform dependency version, update the dependency in `Chart.yaml`.
  Before linting or rendering locally, run
  `helm dependency update platforms/<platform>`.
- To change platform configuration, edit `platforms/<platform>/values.yaml`.
- To change Gitea or Homepage configuration, edit `apps/<app>/values.yaml`.
- To change the Cloudflare connector configuration, edit
  `platforms/cloudflared/values.yaml`.
- To validate a local application chart, run `helm lint apps/<app>` and
  `helm template <app> apps/<app> --namespace <app>`.
- To add a chart, place `application.yaml` beside `Chart.yaml`, then add that
  Application file to the root `kustomization.yaml`.

> This repository is public, so Argo CD can access it over HTTPS without repository
> credentials. Configure an Argo CD repository credential before synchronization if
> the repository is made private.

> Gitea still requires the `gitea/gitea-secret` Secret and a PostgreSQL instance at
> the address configured in `apps/gitea/values.yaml`. These dependencies are not yet
> defined in this repository.

## Argo CD GitHub login

Argo CD uses its bundled Dex server for GitHub OAuth. The public URL is
`https://argocd.huukiet.com`, and the OAuth credentials are read from Vault through
External Secrets. The credentials are never stored in Git.

Create an OAuth App under GitHub **Settings > Developer settings > OAuth Apps** with:

```text
Application name: Argo CD
Homepage URL: https://argocd.huukiet.com
Authorization callback URL: https://argocd.huukiet.com/api/dex/callback
```

Deploy the Git revision containing the Argo CD configuration, then write the OAuth
client ID and client secret to Vault:

```bash
git pull --ff-only origin master
bash deploy.sh
bash scripts/configure-argocd-github-oauth.sh
```

The script securely prompts for the Vault root token and both OAuth values. It creates
a Vault policy and Kubernetes auth role restricted to the
`argocd/argocd-vault-auth` ServiceAccount, writes the credentials to
`kv/homeserver/argocd`, waits for External Secrets, and restarts the Argo CD server
and Dex.

Open `https://argocd.huukiet.com` and choose **Log in via GitHub**. RBAC grants
`role:admin` only to the stable GitHub user ID `20751267` (`KanNguyenKiet`). Other
GitHub identities receive the empty default role and cannot access Argo CD resources.
The built-in local `admin` account remains enabled as a recovery path; disable it only
after GitHub login has been verified.

Verify the secret integration and Dex rollout with:

```bash
kubectl -n argocd get secretstore vault-backend
kubectl -n argocd get externalsecret argocd-github-oauth
kubectl -n argocd rollout status deployment/argocd-dex-server
kubectl -n argocd rollout status deployment/argocd-server
kubectl -n argocd logs deployment/argocd-dex-server --tail=100
```

## HashiCorp Vault

Vault runs as one Raft member with a retained 10 GiB persistent volume. This matches the
current single-node home server but is not highly available. The Vault UI is enabled as
a ClusterIP service and is not exposed through an Ingress. Traffic between Vault and
in-cluster clients currently uses HTTP and never leaves the cluster network.

The first GitOps deployment creates Vault uninitialized and sealed. A Vault Pod showing
`0/1` Ready and a pending Cloudflared Pod are expected until the bootstrap is completed.
Install `jq`, deploy the Git revision, then initialize Vault:

```bash
sudo apt-get update
sudo apt-get install -y jq

git pull --ff-only origin master
bash deploy.sh

VAULT_INIT_OUTPUT=/absolute/path/outside/repo/vault-init.json \
  bash scripts/bootstrap-vault.sh
```

The bootstrap script:

- Creates three Shamir unseal key shares with a threshold of two.
- Saves the unseal keys and initial root token with mode `0600` at
  `VAULT_INIT_OUTPUT`.
- Enables a KV v2 engine at `kv/` and Kubernetes authentication at `kubernetes/`.
- Creates a read-only policy and role restricted to the Cloudflared ServiceAccount.
- Prompts for the Cloudflare tunnel token and writes it to
  `kv/homeserver/cloudflared`.
- Waits for External Secrets and the Cloudflared Deployment to become Ready.

Immediately move the recovery file to encrypted offline storage, separate its unseal
key shares, and delete the server copy. Never store the recovery file, root token, or
unseal keys in this repository or in the Kubernetes cluster. The tunnel token's source
of truth is Vault; External Secrets deliberately materializes it as the target
Kubernetes Secret required by Cloudflared.

Vault must be unsealed after its Pod is recreated or the server restarts:

```bash
bash scripts/unseal-vault.sh
```

The script securely prompts for two different unseal key shares. To rotate the
Cloudflare tunnel token, make sure Vault is unsealed and run
`bash scripts/bootstrap-vault.sh` again; it will skip initialization and prompt for the
root token and replacement tunnel token.

Access the Vault UI only through a temporary local port forward:

```bash
kubectl -n vault port-forward service/vault-ui 8200:8200
```

Then open `http://127.0.0.1:8200`. Back up the Vault Raft data regularly; the retained
PVC protects against accidental workload deletion but is not a backup.

## Cloudflare Tunnel

External Secrets authenticates to Vault with a short-lived Kubernetes ServiceAccount
token. It reads `kv/homeserver/cloudflared`, creates the
`cloudflared/cloudflared-token` Kubernetes Secret, and refreshes it hourly. No static
Vault credential or Cloudflare token is stored in Git.

Verify the integration after Vault bootstrap:

```bash
kubectl -n cloudflared get secretstore vault-backend
kubectl -n cloudflared get externalsecret cloudflared-token
kubectl -n cloudflared rollout status deployment/cloudflared
kubectl -n cloudflared get pods
```

For Homepage, configure the tunnel's public hostname route in the Cloudflare dashboard
with this service URL:

```text
http://homepage.homepage.svc.cluster.local:3000
```

Wait until both Kubernetes connector replicas are Ready and the tunnel is Healthy in
Cloudflare before removing the host daemon. If the old daemon and Kubernetes pods run
at the same time during migration, keep the current node IP/NodePort route until the
old daemon is stopped; a daemon running on the host cannot resolve Kubernetes service
DNS names.

Stop and remove the old systemd service only after the Kubernetes connectors are
healthy:

```bash
sudo systemctl stop cloudflared.service
sudo cloudflared service uninstall
sudo systemctl daemon-reload
systemctl status cloudflared.service --no-pager || true
```

The uninstall command removes the system service but keeps the `cloudflared` binary.
If it was installed as an Ubuntu package and the binary is no longer needed, remove it
separately:

```bash
sudo apt-get remove --purge -y cloudflared
sudo apt-get autoremove -y
```
