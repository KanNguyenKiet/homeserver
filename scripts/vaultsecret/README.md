# vaultsecret

A small, dependency-free Go CLI for writing Vault KV v2 secrets and the
surrounding Kubernetes auth wiring, without hand-rolling a shell script per
integration. Given a secret path and a set of fields, it can wait for Vault,
prompt for the root token, write a read-only policy, write a Kubernetes auth
role bound to one ServiceAccount, write the secret fields into Vault, then
wait for External Secrets to sync the resulting Kubernetes Secret. Adding a
new secret to Vault never requires a new shell script; see the top-level
`README.md` for how the Gitea, Argo CD, and Tailscale sections use it.

## How it reaches Vault

Vault is only ever reached through `kubectl exec` into the Vault Pod. The
tool never needs network access to Vault itself. Secret values are sent over
the exec stdin pipe (one line per field, read remotely with `IFS= read -r`)
and are never printed, passed as command-line arguments, or set as an
environment variable of a child process.

## Build

Requires Go 1.25+. The module has zero third-party dependencies, so building
it never requires network access:

```bash
go build -o vaultsecret .
```

## Usage

Preview any invocation without contacting the cluster with `-dry-run`. For
example, this writes Gitea's database credentials (see the top-level
`README.md`'s "Native PostgreSQL for apps" section):

```bash
./vaultsecret -dry-run \
  -path homeserver/gitea \
  -set-prompt dbName -set-prompt dbUser -set-prompt dbPassword \
  -policy gitea-db-read -role gitea \
  -bound-sa gitea-vault-auth -bound-namespace gitea \
  -wait-externalsecret gitea-secret -app-namespace gitea
```

Drop `-dry-run` to run it for real. It waits for Vault to be initialized and
unsealed, prompts for the Vault root token (or reads `VAULT_ROOT_TOKEN` from
the environment) and for each `-set-prompt` field, writes the policy and
Kubernetes auth role, writes the KV v2 secret, then waits for the named
`SecretStore`/`ExternalSecret` to sync and force-syncs it.

To update only some fields of an existing multi-field secret, such as
rotating one credential without touching the others, add `-patch`; without
it, the tool performs a full `vault kv put`, which replaces every field in
that secret with whatever this invocation supplies.

Run `./vaultsecret -h` for the full flag reference. The most useful flags:

| Flag | Purpose |
| --- | --- |
| `-path` | Secret path under the mount, e.g. `homeserver/gitea` (required) |
| `-mount` | KV v2 mount (default `kv`) |
| `-set key=value` | Field written directly; avoid for real secrets |
| `-set-prompt key` | Field read from a hidden terminal prompt |
| `-set-file key=/path` | Field read from a file |
| `-set-env key=ENV_VAR` | Field read from an environment variable |
| `-patch` | Merge fields into an existing secret instead of overwriting it |
| `-policy` / `-policy-capabilities` | Create/update a policy for this path |
| `-role`, `-bound-sa`, `-bound-namespace`, `-audience`, `-role-ttl`, `-policy-ref` | Create/update a Kubernetes auth role |
| `-wait-externalsecret`, `-secretstore`, `-app-namespace` | Wait for and force-sync the resulting `ExternalSecret` |
| `-restart` | Rollout-restart a Deployment in `-app-namespace` after the sync |
| `-vault-namespace`, `-vault-pod`, `-wait-timeout` | Override Vault Pod location and kubectl wait/rollout timeouts |
| `-dry-run` | Print the plan without contacting Vault or the cluster |

## Examples

Tailscale operator OAuth credentials (see the top-level `README.md`'s
"Tailscale Kubernetes Operator" section):

```bash
./vaultsecret \
  -path homeserver/tailscale \
  -set-prompt clientId -set-prompt clientSecret \
  -policy tailscale-oauth-read -role tailscale \
  -bound-sa tailscale-vault-auth -bound-namespace tailscale \
  -wait-externalsecret operator-oauth -app-namespace tailscale
```

Argo CD GitHub OAuth credentials (see the top-level `README.md`'s "Argo CD
GitHub login" section), followed by a restart of the components that read
them:

```bash
./vaultsecret \
  -path homeserver/argocd \
  -set-prompt githubClientID -set-prompt githubClientSecret \
  -policy argocd-github-oauth-read -role argocd \
  -bound-sa argocd-vault-auth -bound-namespace argocd \
  -wait-externalsecret argocd-github-oauth -app-namespace argocd \
  -restart argocd-dex-server -restart argocd-server
```

Rotate a single field on an existing secret without disturbing the others:

```bash
./vaultsecret -path homeserver/gitea -patch -set-prompt dbPassword
```
