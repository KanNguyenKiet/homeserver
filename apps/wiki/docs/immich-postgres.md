# Immich host PostgreSQL setup

Immich shares the native PostgreSQL 16 instance with Gitea (`192.168.100.10:5432`).
The Immich database is separate; the instance must provide **pgvector** and
**VectorChord** before the Immich app syncs.

Follow [Immich postgres-standalone](https://docs.immich.app/administration/postgres-standalone/)
on the Ubuntu host. Expect a short Gitea outage when PostgreSQL restarts.

## 1. Install pgvector

Add the [PostgreSQL Apt repository](https://wiki.postgresql.org/wiki/Apt) if needed,
then:

```bash
sudo apt update
sudo apt install postgresql-16-pgvector
```

Ensure pgvector is at least `0.7.0`. In psql:

```sql
ALTER EXTENSION vector UPDATE;
```

## 2. Install VectorChord

Install VectorChord for PostgreSQL 16 using
[TensorChord instructions](https://docs.immich.app/administration/postgres-standalone/).

Add to `postgresql.conf` (merge with existing libraries):

```text
shared_preload_libraries = 'vchord.so'
```

If other libraries are already listed, comma-separate them, for example:

```text
shared_preload_libraries = 'pg_stat_statements, vchord.so'
```

Restart PostgreSQL:

```bash
sudo systemctl restart postgresql
```

## 3. Create database and role

Replace the password with a strong value; store the same values in Vault
(`homeserver/immich`) for External Secrets.

```bash
sudo -u postgres psql <<'EOF'
CREATE USER immich WITH PASSWORD 'CHANGE_ME';
CREATE DATABASE immich OWNER immich;
GRANT ALL PRIVILEGES ON DATABASE immich TO immich;
EOF
```

Connect to the Immich database and enable extensions:

```bash
sudo -u postgres psql -d immich <<'EOF'
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
EOF
```

Verify:

```bash
sudo -u postgres psql -d immich -c '\dx'
```

You should see `vector` and `vchord` (and dependencies).

## 4. Network access from pods

Ensure `pg_hba.conf` still allows the k3s Pod CIDR (`10.42.0.0/16`), same as Gitea.
PostgreSQL should listen on the LAN address used in app values (`192.168.100.10`).

## 5. Vault secret

After the database exists, write credentials with `vaultsecret` (see
[Secret management](secrets.md#writing-secrets-with-vaultsecret)):

```bash
scripts/vaultsecret/vaultsecret \
  -path homeserver/immich -patch \
  -set dbName=immich \
  -set dbUser=immich \
  -set-prompt dbPassword \
  -wait-externalsecret immich-secret -app-namespace immich
```

Do not set `DB_VECTOR_EXTENSION=pgvector`; Immich should use VectorChord.

## Upgrades

When upgrading Immich, check release notes for compatible **VectorChord** and
**pgvector** version ranges. Upgrading host extensions or restarting PostgreSQL
affects **both** Gitea and Immich.
