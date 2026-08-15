#!/usr/bin/env bash

set -Eeuo pipefail

readonly ZFS_POOL_NAME="${IMMICH_ZFS_POOL:-tank}"
readonly ZFS_DATASET="${IMMICH_ZFS_DATASET:-${ZFS_POOL_NAME}/immich}"
readonly ZFS_MOUNTPOINT="${IMMICH_ZFS_MOUNTPOINT:-/tank/immich}"
readonly IMMICH_LIBRARY_DIR="${IMMICH_LIBRARY_DIR:-${ZFS_MOUNTPOINT}/library}"

readonly POSTGRES_VERSION="${IMMICH_POSTGRES_VERSION:-16}"
readonly POSTGRES_CLUSTER="${IMMICH_POSTGRES_CLUSTER:-immich}"
readonly POSTGRES_PORT="${IMMICH_POSTGRES_PORT:-5433}"
readonly POSTGRES_LISTEN_ADDRESS="${IMMICH_POSTGRES_LISTEN_ADDRESS:-192.168.100.11}"
readonly K3S_POD_CIDR="${IMMICH_K3S_POD_CIDR:-10.42.0.0/16}"
readonly IMMICH_DB_NAME="${IMMICH_DB_NAME:-immich}"
readonly IMMICH_DB_USER="${IMMICH_DB_USER:-immich}"

readonly VECTORCHORD_VERSION="1.1.1"
readonly VECTORCHORD_PACKAGE_VERSION="${VECTORCHORD_VERSION}-1"
readonly HBA_BEGIN_MARKER="# BEGIN homeserver-immich"
readonly HBA_END_MARKER="# END homeserver-immich"

TEMP_DIR=""
HBA_TEMP_FILE=""
HBA_BACKUP_FILE=""
IMMICH_DB_PASSWORD=""
IMMICH_DB_PASSWORD_CONFIRM=""

cleanup() {
  unset IMMICH_DB_PASSWORD IMMICH_DB_PASSWORD_CONFIRM

  if [[ -n "$HBA_TEMP_FILE" && -f "$HBA_TEMP_FILE" ]]; then
    rm -f -- "$HBA_TEMP_FILE"
  fi
  if [[ -n "$HBA_BACKUP_FILE" && -f "$HBA_BACKUP_FILE" ]]; then
    rm -f -- "$HBA_BACKUP_FILE"
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    case "$TEMP_DIR" in
      /tmp/immich-vectorchord.*)
        find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type f -delete
        rmdir -- "$TEMP_DIR"
        ;;
      *)
        printf 'WARNING: Refusing to clean unexpected temporary path: %s\n' \
          "$TEMP_DIR" >&2
        ;;
    esac
  fi
}

trap cleanup EXIT

log() {
  printf '\n==> %s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: sudo bash scripts/bootstrap-immich-host.sh

Creates the Immich ZFS dataset and bootstraps its dedicated PostgreSQL cluster.
The script is idempotent and securely prompts for the Immich database password.

Optional environment overrides:
  IMMICH_ZFS_POOL                 default: tank
  IMMICH_ZFS_DATASET              default: <pool>/immich
  IMMICH_ZFS_MOUNTPOINT           default: /tank/immich
  IMMICH_LIBRARY_DIR              default: <mountpoint>/library
  IMMICH_POSTGRES_LISTEN_ADDRESS  default: 192.168.100.11
  IMMICH_POSTGRES_PORT            default: 5433
  IMMICH_K3S_POD_CIDR             default: 10.42.0.0/16

When overriding the database address, port, library path, or database names,
make the corresponding change in apps/immich/values.yaml before deployment.
EOF
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

package_is_installed() {
  [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true)" == "ii " ]]
}

is_ipv4() {
  local address="$1"
  local octet
  local -a octets

  IFS='.' read -r -a octets <<<"$address"
  ((${#octets[@]} == 4)) || return 1

  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

is_ipv4_cidr() {
  local cidr="$1"
  local address="${cidr%/*}"
  local prefix="${cidr#*/}"

  [[ "$cidr" == */* && "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
  is_ipv4 "$address" || return 1
  ((10#$prefix <= 32))
}

psql_admin() {
  local database="$1"
  shift
  runuser -u postgres -- psql \
    --no-psqlrc \
    --set ON_ERROR_STOP=1 \
    --port "$POSTGRES_PORT" \
    --dbname "$database" \
    "$@"
}

psql_scalar() {
  local database="$1"
  local query="$2"

  psql_admin "$database" --tuples-only --no-align --command "$query" \
    | tr -d '\r' \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

validate_configuration() {
  [[ "$POSTGRES_VERSION" =~ ^[0-9]+$ ]] \
    || fail "IMMICH_POSTGRES_VERSION must be numeric"
  if [[ ! "$POSTGRES_PORT" =~ ^[0-9]+$ ]] \
    || ((POSTGRES_PORT < 1 || POSTGRES_PORT > 65535)); then
    fail "Invalid IMMICH_POSTGRES_PORT: $POSTGRES_PORT"
  fi
  is_ipv4 "$POSTGRES_LISTEN_ADDRESS" \
    || fail "Invalid IMMICH_POSTGRES_LISTEN_ADDRESS: $POSTGRES_LISTEN_ADDRESS"
  is_ipv4_cidr "$K3S_POD_CIDR" \
    || fail "Invalid IMMICH_K3S_POD_CIDR: $K3S_POD_CIDR"
  [[ "$IMMICH_DB_NAME" =~ ^[a-z_][a-z0-9_]*$ ]] \
    || fail "IMMICH_DB_NAME must be a lowercase PostgreSQL identifier"
  [[ "$IMMICH_DB_USER" =~ ^[a-z_][a-z0-9_]*$ ]] \
    || fail "IMMICH_DB_USER must be a lowercase PostgreSQL identifier"
}

install_required_packages() {
  local package
  local -a packages=(
    ca-certificates
    curl
    "postgresql-${POSTGRES_VERSION}"
    "postgresql-client-${POSTGRES_VERSION}"
    "postgresql-${POSTGRES_VERSION}-pgvector"
    zfsutils-linux
  )
  local -a missing_packages=()

  for package in "${packages[@]}"; do
    if ! package_is_installed "$package"; then
      missing_packages+=("$package")
    fi
  done

  if ((${#missing_packages[@]} == 0)); then
    log "Required host packages are already installed"
    return
  fi

  log "Installing required host packages: ${missing_packages[*]}"
  apt-get update

  for package in "${missing_packages[@]}"; do
    apt-cache show "$package" >/dev/null 2>&1 \
      || fail "APT package $package is unavailable; configure the PostgreSQL PGDG repository first"
  done

  DEBIAN_FRONTEND=noninteractive apt-get install -y -- "${missing_packages[@]}"
}

ensure_vectorchord() {
  local architecture
  local checksum
  local deb_file
  local download_url
  local installed_version=""
  local package_name="postgresql-${POSTGRES_VERSION}-vchord"

  installed_version="$(dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null || true)"
  if [[ -n "$installed_version" ]]; then
    dpkg --compare-versions "$installed_version" ge "2.0" \
      && fail "Installed VectorChord $installed_version is outside Immich's supported < 2.0 range"

    if dpkg --compare-versions "$installed_version" ge "$VECTORCHORD_PACKAGE_VERSION"; then
      log "VectorChord package $installed_version is already installed"
      return
    fi
  fi

  architecture="$(dpkg --print-architecture)"
  case "$architecture" in
    amd64)
      checksum="0109f45cc84e91927f1d8782a2fbe3149a25f03ace7697970fd4860944e7199d"
      ;;
    arm64)
      checksum="d0e5e801644adac8f9492cf506a4668d8571eeb6ca09c6984ecea6e4882db8d5"
      ;;
    *)
      fail "VectorChord $VECTORCHORD_VERSION has no configured package checksum for architecture $architecture"
      ;;
  esac

  TEMP_DIR="$(mktemp -d /tmp/immich-vectorchord.XXXXXX)"
  deb_file="${TEMP_DIR}/${package_name}_${VECTORCHORD_PACKAGE_VERSION}_${architecture}.deb"
  download_url="https://github.com/supervc-stack/VectorChord/releases/download/${VECTORCHORD_VERSION}/$(basename -- "$deb_file")"

  log "Downloading and verifying VectorChord $VECTORCHORD_VERSION"
  curl --fail --location --proto '=https' --tlsv1.2 \
    --output "$deb_file" "$download_url"
  printf '%s  %s\n' "$checksum" "$deb_file" | sha256sum --check --status \
    || fail "VectorChord package checksum verification failed"

  DEBIAN_FRONTEND=noninteractive apt-get install -y -- "$deb_file"
}

ensure_zfs_dataset() {
  local actual_mountpoint
  local mounted
  local source

  log "Preparing ZFS dataset $ZFS_DATASET"
  zpool list -H -o name "$ZFS_POOL_NAME" >/dev/null 2>&1 \
    || fail "ZFS pool $ZFS_POOL_NAME does not exist or is not imported"

  [[ "$ZFS_DATASET" == "$ZFS_POOL_NAME/"* ]] \
    || fail "IMMICH_ZFS_DATASET must be a child of $ZFS_POOL_NAME"
  [[ "$ZFS_MOUNTPOINT" == /* && "$ZFS_MOUNTPOINT" != "/" ]] \
    || fail "IMMICH_ZFS_MOUNTPOINT must be an absolute non-root path"
  case "$IMMICH_LIBRARY_DIR" in
    "$ZFS_MOUNTPOINT"/*) ;;
    *) fail "IMMICH_LIBRARY_DIR must be inside $ZFS_MOUNTPOINT" ;;
  esac

  if zfs list -H -o name "$ZFS_DATASET" >/dev/null 2>&1; then
    actual_mountpoint="$(zfs get -H -o value mountpoint "$ZFS_DATASET")"
    [[ "$actual_mountpoint" == "$ZFS_MOUNTPOINT" ]] \
      || fail "$ZFS_DATASET is mounted at $actual_mountpoint, expected $ZFS_MOUNTPOINT"
  else
    if findmnt --mountpoint "$ZFS_MOUNTPOINT" >/dev/null 2>&1; then
      fail "$ZFS_MOUNTPOINT is already used by another mounted filesystem"
    fi
    if [[ -e "$ZFS_MOUNTPOINT" ]]; then
      [[ -d "$ZFS_MOUNTPOINT" && ! -L "$ZFS_MOUNTPOINT" ]] \
        || fail "$ZFS_MOUNTPOINT exists and is not a regular directory"
      [[ -z "$(find "$ZFS_MOUNTPOINT" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
        || fail "$ZFS_MOUNTPOINT is not empty; refusing to hide existing files beneath a new mount"
    fi

    zfs create \
      -o mountpoint="$ZFS_MOUNTPOINT" \
      -o compression=lz4 \
      -o atime=off \
      "$ZFS_DATASET"
  fi

  mounted="$(zfs get -H -o value mounted "$ZFS_DATASET")"
  if [[ "$mounted" != "yes" ]]; then
    zfs mount "$ZFS_DATASET"
  fi

  [[ ! -L "$IMMICH_LIBRARY_DIR" ]] \
    || fail "$IMMICH_LIBRARY_DIR must not be a symbolic link"
  install -d -m 0755 -- "$IMMICH_LIBRARY_DIR"

  source="$(findmnt -n -o SOURCE --target "$IMMICH_LIBRARY_DIR")"
  [[ "$source" == "$ZFS_DATASET" ]] \
    || fail "$IMMICH_LIBRARY_DIR resolves to $source instead of $ZFS_DATASET"

  printf 'ZFS dataset: %s -> %s\n' "$ZFS_DATASET" "$IMMICH_LIBRARY_DIR"
}

cluster_exists() {
  pg_lsclusters --no-header \
    | awk -v version="$POSTGRES_VERSION" -v cluster="$POSTGRES_CLUSTER" \
        '$1 == version && $2 == cluster { found = 1 } END { exit !found }'
}

cluster_port() {
  pg_lsclusters --no-header \
    | awk -v version="$POSTGRES_VERSION" -v cluster="$POSTGRES_CLUSTER" \
        '$1 == version && $2 == cluster { print $3; exit }'
}

cluster_status() {
  pg_lsclusters --no-header \
    | awk -v version="$POSTGRES_VERSION" -v cluster="$POSTGRES_CLUSTER" \
        '$1 == version && $2 == cluster { print $4; exit }'
}

ensure_cluster_port_is_available() {
  local owner

  owner="$({
    pg_lsclusters --no-header \
      | awk -v port="$POSTGRES_PORT" '$3 == port { print $1 "/" $2 }'
  } || true)"

  if [[ -n "$owner" && "$owner" != "$POSTGRES_VERSION/$POSTGRES_CLUSTER" ]]; then
    fail "PostgreSQL port $POSTGRES_PORT is already assigned to $owner"
  fi
}

configure_postgres_settings() {
  local current_preloads
  local normalized_preloads
  local requested_preloads

  current_preloads="$(psql_scalar postgres 'SHOW shared_preload_libraries;')"
  normalized_preloads="${current_preloads//[[:space:]]/}"
  case ",$normalized_preloads," in
    *,vchord,* | *,vchord.so,*) requested_preloads="$current_preloads" ;;
    *) requested_preloads="${current_preloads:+${current_preloads},}vchord.so" ;;
  esac

  psql_admin postgres \
    --set listen_addresses="localhost,${POSTGRES_LISTEN_ADDRESS}" \
    --set preload_libraries="$requested_preloads" <<'SQL'
ALTER SYSTEM SET listen_addresses = :'listen_addresses';
ALTER SYSTEM SET password_encryption = 'scram-sha-256';
ALTER SYSTEM SET shared_preload_libraries = :'preload_libraries';
SQL

  pg_ctlcluster "$POSTGRES_VERSION" "$POSTGRES_CLUSTER" restart

  [[ "$(psql_scalar postgres 'SHOW port;')" == "$POSTGRES_PORT" ]] \
    || fail "PostgreSQL cluster is not listening on port $POSTGRES_PORT"
  [[ "$(psql_scalar postgres 'SHOW shared_preload_libraries;')" == *vchord* ]] \
    || fail "VectorChord is not present in shared_preload_libraries"
}

configure_pg_hba() {
  local begin_count
  local end_count
  local hba_file
  local hba_rule
  local parse_errors

  hba_file="$(psql_scalar postgres 'SHOW hba_file;')"
  [[ -f "$hba_file" ]] || fail "PostgreSQL HBA file does not exist: $hba_file"

  begin_count="$(grep -Fxc "$HBA_BEGIN_MARKER" "$hba_file" || true)"
  end_count="$(grep -Fxc "$HBA_END_MARKER" "$hba_file" || true)"
  [[ "$begin_count" == "$end_count" && "$begin_count" -le 1 ]] \
    || fail "Managed Immich block markers are inconsistent in $hba_file"

  HBA_TEMP_FILE="$(mktemp --tmpdir="$(dirname -- "$hba_file")" .pg_hba.XXXXXX)"
  HBA_BACKUP_FILE="$(mktemp --tmpdir="$(dirname -- "$hba_file")" .pg_hba.backup.XXXXXX)"
  cp --preserve=mode,ownership -- "$hba_file" "$HBA_BACKUP_FILE"

  awk -v begin="$HBA_BEGIN_MARKER" -v end="$HBA_END_MARKER" '
    $0 == begin { managed = 1; next }
    $0 == end { managed = 0; next }
    !managed { print }
  ' "$hba_file" >"$HBA_TEMP_FILE"

  hba_rule="host  ${IMMICH_DB_NAME}  ${IMMICH_DB_USER}  ${K3S_POD_CIDR}  scram-sha-256"
  printf '\n%s\n%s\n%s\n' \
    "$HBA_BEGIN_MARKER" "$hba_rule" "$HBA_END_MARKER" >>"$HBA_TEMP_FILE"
  chmod --reference="$hba_file" "$HBA_TEMP_FILE"
  chown --reference="$hba_file" "$HBA_TEMP_FILE"
  mv -- "$HBA_TEMP_FILE" "$hba_file"
  HBA_TEMP_FILE=""

  pg_ctlcluster "$POSTGRES_VERSION" "$POSTGRES_CLUSTER" reload
  parse_errors="$(psql_scalar postgres \
    "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;")"

  if [[ "$parse_errors" != "0" ]]; then
    cp --preserve=mode,ownership -- "$HBA_BACKUP_FILE" "$hba_file"
    pg_ctlcluster "$POSTGRES_VERSION" "$POSTGRES_CLUSTER" reload
    fail "PostgreSQL rejected the generated pg_hba.conf; the previous file was restored"
  fi

  rm -f -- "$HBA_BACKUP_FILE"
  HBA_BACKUP_FILE=""
}

prompt_for_database_password() {
  [[ -r /dev/tty ]] || fail "An interactive terminal is required for the database password"

  read -r -s -p "Immich PostgreSQL password: " IMMICH_DB_PASSWORD </dev/tty
  printf '\n' >/dev/tty
  read -r -s -p "Confirm Immich PostgreSQL password: " \
    IMMICH_DB_PASSWORD_CONFIRM </dev/tty
  printf '\n' >/dev/tty

  [[ -n "$IMMICH_DB_PASSWORD" ]] || fail "Database password cannot be empty"
  [[ "$IMMICH_DB_PASSWORD" == "$IMMICH_DB_PASSWORD_CONFIRM" ]] \
    || fail "Database passwords do not match"
  unset IMMICH_DB_PASSWORD_CONFIRM
}

create_database_and_extensions() {
  local vector_version
  local vchord_version

  log "Creating the Immich role, database, and extensions"
  prompt_for_database_password

  {
    printf "\\prompt '' db_password\n"
    printf '%s\n' "$IMMICH_DB_PASSWORD"
    cat <<'SQL'
SELECT format('CREATE ROLE %I LOGIN SUPERUSER', :'db_user')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'db_user'
)\gexec

SELECT format(
  'ALTER ROLE %I WITH LOGIN SUPERUSER PASSWORD %L',
  :'db_user', :'db_password'
)\gexec

SELECT format(
  'CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING ''UTF8''',
  :'db_name', :'db_user'
)
WHERE NOT EXISTS (
  SELECT 1 FROM pg_database WHERE datname = :'db_name'
)\gexec

SELECT format('ALTER DATABASE %I OWNER TO %I', :'db_name', :'db_user')\gexec
SELECT format('REVOKE ALL ON DATABASE %I FROM PUBLIC', :'db_name')\gexec
SELECT format(
  'GRANT CONNECT, TEMPORARY ON DATABASE %I TO %I',
  :'db_name', :'db_user'
)\gexec
SQL
  } | psql_admin postgres \
    --set db_name="$IMMICH_DB_NAME" \
    --set db_user="$IMMICH_DB_USER"

  unset IMMICH_DB_PASSWORD

  psql_admin "$IMMICH_DB_NAME" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
CREATE EXTENSION IF NOT EXISTS earthdistance CASCADE;
SQL

  vector_version="$(psql_scalar "$IMMICH_DB_NAME" \
    "SELECT extversion FROM pg_extension WHERE extname = 'vector';")"
  vchord_version="$(psql_scalar "$IMMICH_DB_NAME" \
    "SELECT extversion FROM pg_extension WHERE extname = 'vchord';")"

  [[ -n "$vector_version" && -n "$vchord_version" ]] \
    || fail "Immich database extensions were not created"
  if ! dpkg --compare-versions "$vector_version" ge "0.7" \
    || ! dpkg --compare-versions "$vector_version" lt "0.9"; then
    fail "pgvector $vector_version is outside Immich's supported >= 0.7, < 0.9 range"
  fi
  if ! dpkg --compare-versions "$vchord_version" ge "0.3" \
    || ! dpkg --compare-versions "$vchord_version" lt "2.0"; then
    fail "VectorChord $vchord_version is outside Immich's supported >= 0.3, < 2.0 range"
  fi

  printf 'PostgreSQL extensions: vector=%s, vchord=%s, earthdistance=enabled\n' \
    "$vector_version" "$vchord_version"
}

configure_firewall_if_active() {
  if ! command -v ufw >/dev/null 2>&1; then
    return
  fi
  if ! ufw status | grep -q '^Status: active'; then
    return
  fi

  log "Allowing k3s Pod traffic to PostgreSQL through UFW"
  ufw allow from "$K3S_POD_CIDR" to "$POSTGRES_LISTEN_ADDRESS" \
    port "$POSTGRES_PORT" proto tcp
}

ensure_postgres_cluster() {
  local cluster_data_dir
  local cluster_filesystem

  log "Preparing PostgreSQL $POSTGRES_VERSION/$POSTGRES_CLUSTER"
  ip -4 -o address show \
    | awk '{ sub(/\/.*/, "", $4); print $4 }' \
    | grep -Fxq "$POSTGRES_LISTEN_ADDRESS" \
    || fail "$POSTGRES_LISTEN_ADDRESS is not assigned to this host"

  ensure_cluster_port_is_available
  if cluster_exists; then
    log "PostgreSQL cluster $POSTGRES_VERSION/$POSTGRES_CLUSTER already exists"
    [[ "$(cluster_port)" == "$POSTGRES_PORT" ]] \
      || fail "Existing cluster uses port $(cluster_port), expected $POSTGRES_PORT"
    if [[ "$(cluster_status)" != "online" ]]; then
      pg_ctlcluster "$POSTGRES_VERSION" "$POSTGRES_CLUSTER" start \
        || fail "Unable to start PostgreSQL cluster $POSTGRES_VERSION/$POSTGRES_CLUSTER"
    fi
  else
    pg_createcluster "$POSTGRES_VERSION" "$POSTGRES_CLUSTER" \
      --port="$POSTGRES_PORT" --start
  fi

  configure_postgres_settings
  cluster_data_dir="$(psql_scalar postgres 'SHOW data_directory;')"
  cluster_filesystem="$(findmnt -n -o FSTYPE --target "$cluster_data_dir")"
  case "$cluster_filesystem" in
    nfs | nfs4 | cifs | smb3)
      fail "PostgreSQL data directory is on unsupported network filesystem $cluster_filesystem"
      ;;
  esac

  configure_pg_hba
  create_database_and_extensions
  configure_firewall_if_active

  pg_isready --host "$POSTGRES_LISTEN_ADDRESS" --port "$POSTGRES_PORT" >/dev/null \
    || fail "PostgreSQL is not reachable at $POSTGRES_LISTEN_ADDRESS:$POSTGRES_PORT"
  printf 'PostgreSQL cluster: %s/%s on %s:%s (%s at %s)\n' \
    "$POSTGRES_VERSION" "$POSTGRES_CLUSTER" \
    "$POSTGRES_LISTEN_ADDRESS" "$POSTGRES_PORT" \
    "$cluster_filesystem" "$cluster_data_dir"
}

if (($# > 0)); then
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
fi

((EUID == 0)) || fail "Run this script as root: sudo bash scripts/bootstrap-immich-host.sh"

for command_name in apt-cache apt-get awk dpkg dpkg-query find grep ip mktemp runuser sed sha256sum tr; do
  require_command "$command_name"
done

validate_configuration
install_required_packages

for command_name in curl findmnt pg_createcluster pg_ctlcluster pg_isready pg_lsclusters psql zfs zpool; do
  require_command "$command_name"
done

ensure_vectorchord
ensure_zfs_dataset
ensure_postgres_cluster

log "Immich host prerequisites are ready"
printf '%s\n' \
  "Next: deploy the Immich Application and write dbName, dbUser, and dbPassword to Vault as documented in README.md."
