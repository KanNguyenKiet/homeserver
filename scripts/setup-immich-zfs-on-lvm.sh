#!/usr/bin/env bash
# Create a ZFS pool on a dedicated LVM logical volume for Immich library storage.
# Intended for nodes with free space in ubuntu-vg (e.g. homeserver1 worker).
set -Eeuo pipefail

readonly VG_NAME="${IMMICH_ZFS_VG:-ubuntu-vg}"
readonly LV_NAME="${IMMICH_ZFS_LV:-tank-lv}"
readonly POOL_NAME="${IMMICH_ZFS_POOL:-tank}"
readonly DATASET="${IMMICH_ZFS_DATASET:-${POOL_NAME}/immich}"
readonly MOUNTPOINT="${IMMICH_ZFS_MOUNTPOINT:-/tank/immich}"
readonly LIBRARY_DIR="${IMMICH_LIBRARY_DIR:-${MOUNTPOINT}/library}"
readonly LV_SIZE="${IMMICH_ZFS_LV_SIZE:-350G}"

log() { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

((EUID == 0)) || fail "Run as root: sudo bash $0"

export DEBIAN_FRONTEND=noninteractive
if ! command -v zpool >/dev/null; then
  apt-get update -qq
  apt-get install -y zfsutils-linux
fi

if ! vgs "$VG_NAME" >/dev/null 2>&1; then
  fail "Volume group $VG_NAME not found"
fi

if lvs "${VG_NAME}/${LV_NAME}" >/dev/null 2>&1; then
  log "Logical volume ${VG_NAME}/${LV_NAME} already exists"
else
  log "Creating logical volume ${LV_NAME} (${LV_SIZE}) in ${VG_NAME}"
  lvcreate -L "$LV_SIZE" -n "$LV_NAME" "$VG_NAME"
fi

LV_DEV="/dev/${VG_NAME}/${LV_NAME}"
[[ -b "$LV_DEV" ]] || fail "Block device missing: $LV_DEV"

if zpool list -H -o name "$POOL_NAME" >/dev/null 2>&1; then
  log "ZFS pool $POOL_NAME already exists"
else
  log "Creating ZFS pool $POOL_NAME on $LV_DEV"
  zpool create -f -m none "$POOL_NAME" "$LV_DEV"
fi

if zfs list -H -o name "$DATASET" >/dev/null 2>&1; then
  log "Dataset $DATASET already exists"
else
  log "Creating dataset $DATASET"
  zfs create \
    -o mountpoint="$MOUNTPOINT" \
    -o compression=lz4 \
    -o atime=off \
    "$DATASET"
fi

zfs mount "$DATASET" 2>/dev/null || true
install -d -m 0755 "$LIBRARY_DIR"

for dir in upload library profile thumbs encoded-video backups; do
  install -d -m 0755 "${MOUNTPOINT}/${dir}"
  [[ -f "${MOUNTPOINT}/${dir}/.immich" ]] || echo "immich" >"${MOUNTPOINT}/${dir}/.immich"
done

log "ZFS ready"
zfs list "$DATASET"
df -h "$MOUNTPOINT"
zpool list "$POOL_NAME"
