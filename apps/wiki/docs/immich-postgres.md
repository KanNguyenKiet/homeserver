# In-cluster PostgreSQL

Gitea and Immich each own a PostgreSQL 16 StatefulSet in the app namespace:

| App | Service | Node | Image | PVC |
| --- | --- | --- | --- | --- |
| Gitea | `gitea-postgresql:5432` | `homeserver` | `postgres:16.14` | `gitea-postgresql-data` |
| Immich | `immich-postgresql:5432` | `homeserver1` | `ghcr.io/immich-app/postgres:16-vectorchord1.1.1-pgvector0.8.5` | `immich-postgresql-data` |

Both PVCs use the node-local `local-path` StorageClass. The Helm resources carry
retain/prune protection, but the databases are not replicated: loss of the bound
node or disk still requires a restore from backup.

## Credentials

The PostgreSQL containers and their apps read the same Kubernetes Secret. Gitea
uses `gitea-secret`; Immich uses `immich-database`, which External Secrets
materializes from Vault path `homeserver/immich`.

Do not set `DB_VECTOR_EXTENSION=pgvector`; Immich uses VectorChord. The Immich
database container preloads `vchord.so` and includes compatible VectorChord and
pgvector versions.

## Verify

```bash
kubectl -n gitea get statefulset,pod,pvc,svc -l app.kubernetes.io/component=database
kubectl -n immich get statefulset,pod,pvc,svc -l app.kubernetes.io/component=database

kubectl -n gitea exec gitea-postgresql-0 -- \
  psql -U gitea -d gitea -c 'select version();'
kubectl -n immich exec immich-postgresql-0 -- \
  psql -U immich -d immich -c '\dx'
```

## Backups and upgrades

Take a logical dump before changing a PostgreSQL major version or the Immich
extension image:

```bash
kubectl -n gitea exec gitea-postgresql-0 -- \
  pg_dump -U gitea -d gitea -Fc > gitea.dump
kubectl -n immich exec immich-postgresql-0 -- \
  pg_dump -U immich -d immich -Fc > immich.dump
```

When upgrading Immich, check its release notes for supported **VectorChord** and
**pgvector** versions. Each database is isolated, so restarting or upgrading one
does not interrupt the other app.
