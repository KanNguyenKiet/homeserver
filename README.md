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
|   |-- tailscale/                   # Tailscale Operator and subnet connector
|   `-- vault/                       # HashiCorp Vault wrapper Helm chart
|-- scripts/                         # Vault bootstrap and unseal operations
|   `-- vaultsecret/                 # Generic Go CLI for writing Vault secrets
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

External Secrets, HashiCorp Vault, ingress-nginx, and the Tailscale Operator are local
wrapper Helm charts in `platforms/`. Each chart keeps its `application.yaml` beside
`Chart.yaml`. The upstream chart is declared as a dependency in `Chart.yaml` and
downloaded during the dependency build. Generated `Chart.lock` and `charts/*.tgz` files
are ignored and are not committed.

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
- To change Tailscale routes, tags, or connector settings, edit
  `platforms/tailscale/values.yaml`.
- To validate a local application chart, run `helm lint apps/<app>` and
  `helm template <app> apps/<app> --namespace <app>`.
- To add a chart, place `application.yaml` beside `Chart.yaml`, then add that
  Application file to the root `kustomization.yaml`.

> This repository is public, so Argo CD can access it over HTTPS without repository
> credentials. Configure an Argo CD repository credential before synchronization if
> the repository is made private.

> Gitea still requires the `gitea/gitea-secret` Secret and a PostgreSQL instance at
> the address configured in `apps/gitea/values.yaml`. The Secret is managed through
> Vault and External Secrets, while PostgreSQL runs natively on the homeserver.

## Native PostgreSQL for apps

PostgreSQL is intentionally not deployed through Kubernetes in this setup. Install it
directly on the homeserver, reserve a stable LAN IP or local DNS name for that host,
and let Kubernetes workloads connect to that address.

Install PostgreSQL 16 on Ubuntu:

```bash
sudo apt update
sudo apt install -y postgresql-common
sudo /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh
sudo apt update
sudo apt install -y postgresql-16 postgresql-client-16
sudo systemctl enable --now postgresql
sudo pg_lsclusters
```

Find the server LAN address and Kubernetes Pod CIDR:

```bash
ip -br addr
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
```

Edit `/etc/postgresql/16/main/postgresql.conf` so PostgreSQL listens on localhost
and the server LAN IP:

```conf
listen_addresses = 'localhost,192.168.1.10'
port = 5432
password_encryption = 'scram-sha-256'
```

Edit `/etc/postgresql/16/main/pg_hba.conf` and allow only the app database/user from
the Kubernetes Pod CIDR. Replace the CIDR with the value from the node command above:

```conf
host  gitea  gitea  10.42.0.0/16  scram-sha-256
```

Restart PostgreSQL and confirm it is listening:

```bash
sudo systemctl restart postgresql
sudo systemctl status postgresql --no-pager
sudo ss -lntp | grep 5432
```

If UFW is already enabled, allow only Pod traffic to PostgreSQL:

```bash
sudo ufw allow from 10.42.0.0/16 to 192.168.1.10 port 5432 proto tcp
```

Update `apps/gitea/values.yaml` if the PostgreSQL host is not
`192.168.1.10:5432`, deploy the Git revision, then create the Gitea role and
database. This is safe to re-run; it only creates the role/database if they do
not already exist, and always updates the role's password:

```bash
git pull --ff-only origin master
bash deploy.sh

read -r -s -p "Gitea PostgreSQL password: " GITEA_DB_PASSWORD; echo
sudo -u postgres psql \
  --set ON_ERROR_STOP=1 \
  --set db_password="$GITEA_DB_PASSWORD" <<'SQL'
SELECT format(
  'CREATE ROLE %I LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION',
  'gitea'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = 'gitea'
)\gexec

ALTER ROLE gitea WITH PASSWORD :'db_password';

SELECT format(
  'CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING ''UTF8''',
  'gitea', 'gitea'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = 'gitea'
)\gexec

REVOKE ALL ON DATABASE gitea FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE gitea TO gitea;
SQL
unset GITEA_DB_PASSWORD
```

Then write the same credentials to Vault with `vaultsecret` (see
[Generic Vault secret helper (vaultsecret)](#generic-vault-secret-helper-vaultsecret)
below for how to build it). This creates a Vault policy and Kubernetes auth
role restricted to the `gitea/gitea-vault-auth` ServiceAccount, writes the
credentials to `kv/homeserver/gitea`, and waits for External Secrets to sync
the `gitea/gitea-secret` Secret:

```bash
scripts/vaultsecret/vaultsecret \
  -path homeserver/gitea \
  -set-prompt dbName -set-prompt dbUser -set-prompt dbPassword \
  -policy gitea-db-read -role gitea \
  -bound-sa gitea-vault-auth -bound-namespace gitea \
  -wait-externalsecret gitea-secret -app-namespace gitea
```

Verify Gitea can connect from inside Kubernetes:

```bash
kubectl -n gitea run pg-test --rm -it --restart=Never --image=postgres:16 -- \
  psql -h 192.168.1.10 -U gitea -d gitea -W -c 'select 1;'
kubectl -n gitea rollout status deployment/gitea
```

Back up PostgreSQL outside Kubernetes. A simple starting point is a nightly
`pg_dump -Fc` for each application database plus `pg_dumpall --globals-only`, stored
off the server or on a separate encrypted disk.

## Argo CD GitHub login

Argo CD uses its bundled Dex server for GitHub OAuth. The public URL is
`https://argocd.huukiet.com`, and the OAuth credentials are read from Vault through
External Secrets. The credentials are never stored in Git.

Public TLS terminates upstream of Argo CD. The bundled Dex issuer is reached through
an internal Cloudflare/Ingress route whose origin certificate is not in the
`argocd-server` trust store, so OIDC provider certificate verification is disabled in
`argocd-cm`. Remove this exception after the internal route presents a certificate
issued by a CA trusted by the Argo CD container.

Create an OAuth App under GitHub **Settings > Developer settings > OAuth Apps** with:

```text
Application name: Argo CD
Homepage URL: https://argocd.huukiet.com
Authorization callback URL: https://argocd.huukiet.com/api/dex/callback
```

Deploy the Git revision containing the Argo CD configuration, then write the OAuth
client ID and client secret to Vault with `vaultsecret` (see
[Generic Vault secret helper (vaultsecret)](#generic-vault-secret-helper-vaultsecret)
below for how to build it):

```bash
git pull --ff-only origin master
bash deploy.sh

scripts/vaultsecret/vaultsecret \
  -path homeserver/argocd \
  -set-prompt githubClientID -set-prompt githubClientSecret \
  -policy argocd-github-oauth-read -role argocd \
  -bound-sa argocd-vault-auth -bound-namespace argocd \
  -wait-externalsecret argocd-github-oauth -app-namespace argocd \
  -restart argocd-dex-server -restart argocd-server
```

`vaultsecret` securely prompts for the Vault root token and both OAuth values. It
creates a Vault policy and Kubernetes auth role restricted to the
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

## Generic Vault secret helper (vaultsecret)

`scripts/vaultsecret` is a small, dependency-free Go CLI for writing Vault secrets:
creating a read-only policy, creating a Kubernetes auth role bound to one
ServiceAccount, writing the KV v2 secret fields, and waiting for External Secrets
to sync the result. Adding a new secret to Vault never requires writing a new shell
script; the Gitea, Argo CD, and Tailscale sections above all use it. See
`scripts/vaultsecret/README.md` for the full flag reference and more examples.

Build it once (Go 1.25+, zero third-party dependencies, so no network access is
required to build it):

```bash
cd scripts/vaultsecret
go build -o vaultsecret .
```

Vault is only ever reached through `kubectl exec` into the Vault Pod; the tool
never needs network access to Vault itself. Secret values are sent over the exec
stdin pipe and are never printed, passed as command-line arguments, or set as an
environment variable of a child process.

Preview any invocation without touching the cluster by adding `-dry-run`, for
example:

```bash
./vaultsecret -dry-run \
  -path homeserver/gitea \
  -set-prompt dbName -set-prompt dbUser -set-prompt dbPassword \
  -policy gitea-db-read -role gitea \
  -bound-sa gitea-vault-auth -bound-namespace gitea \
  -wait-externalsecret gitea-secret -app-namespace gitea
```

Drop `-dry-run` to run it for real. It waits for Vault to be initialized and
unsealed, prompts for the Vault root token (or reads `VAULT_ROOT_TOKEN` from the
environment) and for each `-set-prompt` field, writes the policy and Kubernetes
auth role, writes the KV v2 secret, then waits for the named
`SecretStore`/`ExternalSecret` to sync and force-syncs it.

To update only some fields of an existing multi-field secret, such as rotating one
credential without touching the others, add `-patch`; without it, the tool performs
a full `vault kv put`, which replaces every field in that secret with whatever this
invocation supplies. Run `./vaultsecret -h` for the full flag reference, including
`-set-file`, `-set-env`, `-restart` (rollout-restart a Deployment after the sync),
and `-policy-capabilities`.

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

## Tailscale Kubernetes Operator

Tailscale runs in Kubernetes through the official Operator. A single `Connector`
named `homeserver` acts as a subnet router and advertises these networks to the
tailnet:

```text
192.168.1.0/24  homeserver LAN
10.42.0.0/16    default k3s Pod CIDR
10.43.0.0/16    default k3s Service CIDR
```

Confirm the LAN, Pod, and Service CIDRs before deploying. If this cluster was created
with custom ranges, update `connector.subnetRouter.advertiseRoutes` in
`platforms/tailscale/values.yaml`. Avoid using a LAN range that commonly overlaps the
network from which remote clients connect.

In the Tailscale policy file, merge these tag ownership and route approval entries
with the existing policy:

```json
{
  "tagOwners": {
    "tag:k8s-operator": [],
    "tag:k8s": ["tag:k8s-operator"]
  },
  "autoApprovers": {
    "routes": {
      "192.168.1.0/24": ["tag:k8s"],
      "10.42.0.0/16": ["tag:k8s"],
      "10.43.0.0/16": ["tag:k8s"]
    }
  }
}
```

Create an OAuth client in the Tailscale admin console under **Trust credentials**.
Grant write access for **Devices Core**, **Auth Keys**, and **Services**, and assign
the client the `tag:k8s-operator` tag. Save its client ID and secret temporarily; the
secret is shown only once.

Deploy the Git revision first. The Operator Pod initially waiting for the
`operator-oauth` Secret is expected. Then store the OAuth credentials in Vault with
`vaultsecret` (see
[Generic Vault secret helper (vaultsecret)](#generic-vault-secret-helper-vaultsecret)
below for how to build it) and wait for the Operator and Connector:

```bash
git pull --ff-only origin master
bash deploy.sh

scripts/vaultsecret/vaultsecret \
  -path homeserver/tailscale \
  -set-prompt clientId -set-prompt clientSecret \
  -policy tailscale-oauth-read -role tailscale \
  -bound-sa tailscale-vault-auth -bound-namespace tailscale \
  -wait-externalsecret operator-oauth -app-namespace tailscale
```

This creates a Vault policy and Kubernetes auth role restricted to the
`tailscale/tailscale-vault-auth` ServiceAccount. External Secrets reads
`kv/homeserver/tailscale`, creates `tailscale/operator-oauth`, and refreshes it hourly.
No Tailscale OAuth credential is stored in Git.

Verify the deployment and advertised routes:

```bash
kubectl -n tailscale get secretstore,externalsecret
kubectl -n tailscale rollout status deployment/operator
kubectl get connector homeserver
kubectl -n tailscale get pods
```

If route auto-approval was not configured, approve the three routes for the
`homeserver-k8s` machine in the Tailscale admin console. Linux clients must also accept
subnet routes:

```bash
sudo tailscale set --accept-routes=true
```

From a remote tailnet device, test SSH to the homeserver LAN address and any required
cluster address before removing the host daemon:

```bash
ssh <user>@192.168.1.10
```

After the Connector has remained healthy and remote access works, disable the old host
daemon. Keep the package and state directory until the Kubernetes migration has been
verified over several reconnects or a server reboot:

```bash
sudo systemctl disable --now tailscaled
systemctl status tailscaled --no-pager || true
```

The host's old `100.x` Tailscale address stops working when its daemon is disabled.
Use the routed LAN address (`192.168.1.10` in this repository) instead. The Connector
has its own tailnet identity and does not inherit the host daemon's identity or IP.
