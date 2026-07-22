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

## Build the container image locally

```bash
docker build -t ghcr.io/kannguyenkiet/homeserver-wiki:local apps/wiki
docker run --rm -p 8080:8080 ghcr.io/kannguyenkiet/homeserver-wiki:local
```

## Production workflow

1. Edit Markdown files in `docs/`
2. Push to `master`
3. GitHub Actions builds and pushes `ghcr.io/kannguyenkiet/homeserver-wiki:<sha>`
4. The workflow commits the new image tag to `values.yaml`
5. Argo CD syncs the updated Deployment

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
