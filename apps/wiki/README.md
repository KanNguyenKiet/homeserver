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

No GitHub Actions or container registry is required. The homeserver builds the image
locally during deployment.

1. Edit Markdown files in `docs/`
2. Push to `master`
3. On the server, run `bash deploy.sh`
4. The script calls `scripts/build-wiki-image.sh`, which runs `docker build` and
   imports `homeserver-wiki:local` into k3s
5. Argo CD syncs the Deployment. When wiki content changes, a Helm checksum annotation
   changes and Kubernetes rolls the Pod

## Build the image manually

```bash
bash scripts/build-wiki-image.sh
docker run --rm -p 8080:8080 homeserver-wiki:local
```

Requires `docker` and `k3s` on the server.

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
