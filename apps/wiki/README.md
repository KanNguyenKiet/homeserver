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
`git.huukiet.com/ops/homeserver-wiki:<commit-sha>`. Gitea Actions builds and publishes
it; Argo CD deploys the tag pinned in `values.yaml`.

1. Edit Markdown files in `docs/`
2. Push to `master`
3. Gitea Actions (`.gitea/workflows/wiki.yml`) builds the image, pushes
   `git.huukiet.com/ops/homeserver-wiki:<sha>`, updates `apps/wiki/values.yaml`, and
   pushes to GitHub
4. Argo CD syncs the new image tag and Kubernetes rolls the Pod

The workflow only runs when wiki source files change, not when only the image tag in
`values.yaml` is updated (avoids infinite loops).

Before the first deploy, store Gitea registry pull credentials in Vault — see
the repository README **Cluster secrets** section.

## Manual image build

For emergencies when Actions is unavailable:

```bash
docker login git.huukiet.com
bash scripts/build-wiki-image.sh
# commits tag to values.yaml and push to GitHub yourself
docker run --rm -p 8080:8080 git.huukiet.com/ops/homeserver-wiki:$(git rev-parse HEAD)
```

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
