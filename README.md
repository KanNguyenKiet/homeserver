# Homeserver GitOps

This repository uses Argo CD with the app-of-apps pattern. After the initial
bootstrap, Argo CD treats Git as the desired state and automatically synchronizes
platforms and applications to the cluster.

## Structure

```text
homeserver/
|-- apps/                            # Local Helm charts for workloads
|-- platforms/                       # Cluster services
|   `-- argocd/
|       `-- config/                  # Argo CD configuration managed through GitOps
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

After this step, there is no need to run `helm install` or `kubectl apply` for each
application. Make changes through Git commits; Argo CD handles synchronization,
pruning, and self-healing.

Child Applications use resource finalizers. Removing an Application from
`kustomization.yaml` will therefore also delete the Kubernetes resources managed by
that Application. Carefully review this type of change before merging it.

## Helm charts

External Secrets and ingress-nginx are local wrapper Helm charts located in
`platforms/external-secrets/` and `platforms/nginx-ingress/`. Each chart keeps its
`application.yaml` beside `Chart.yaml`. The upstream chart is declared as a dependency
in `Chart.yaml` and downloaded during the dependency build. Generated `Chart.lock` and
`charts/*.tgz` files are ignored and are not committed.

Gitea and Homepage are local Helm charts in `apps/gitea/` and `apps/homepage/`. Argo
CD renders these charts directly from Git. Each application's configuration is stored
in its corresponding `values.yaml` file.

- To change a platform dependency version, update the dependency in `Chart.yaml`.
  Before linting or rendering locally, run
  `helm dependency build platforms/<platform>`.
- To change platform configuration, edit `platforms/<platform>/values.yaml`.
- To change Gitea or Homepage configuration, edit `apps/<app>/values.yaml`.
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
