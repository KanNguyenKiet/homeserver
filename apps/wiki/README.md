# Homeserver Wiki (MkDocs Material)

Static documentation site built with [MkDocs Material](https://squidfunk.github.io/mkdocs-material/)
and served by NGINX in Kubernetes.

## Local preview

```bash
cd apps/wiki
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
mkdocs serve
```

Open http://127.0.0.1:8000

## Production workflow

The wiki image is stored in the Gitea container registry at
`git.huukiet.com/ops/homeserver-wiki`. The homeserver builds and pushes the image
during deployment.

1. Edit Markdown files in `docs/`
2. Push to `master`
3. On the server, run `bash deploy.sh`
4. The script calls `scripts/build-wiki-image.sh`, which runs `docker build`, tags
   `:latest` and the current Git short SHA, and pushes to Gitea
5. Argo CD syncs the Deployment. When wiki content changes, a Helm checksum annotation
   changes and Kubernetes rolls the Pod with `imagePullPolicy: Always`

Before the first deploy, store Gitea registry credentials in Vault so the wiki Pod can
pull the private image. Create a Gitea personal access token with `read:package`
(and `write:package` for the build host), then run `vaultsecret` from the repository
README.

On the server, either run `docker login git.huukiet.com` once or export
`GITEA_REGISTRY_USER` and `GITEA_REGISTRY_TOKEN` before `deploy.sh` so the build script
can push.

## Build the image manually

```bash
docker login git.huukiet.com
bash scripts/build-wiki-image.sh
docker run --rm -p 8080:8080 git.huukiet.com/ops/homeserver-wiki:latest
```

Requires `docker` on the build host and registry credentials with `write:package`.

## Structure

```text
apps/wiki/
|-- docs/              # Markdown source
|-- mkdocs.yml         # Site configuration
|-- requirements.txt   # Python dependencies
|-- Dockerfile         # mkdocs build + nginx serve
|-- nginx/             # NGINX server config
`-- templates/         # Helm chart templates
```
