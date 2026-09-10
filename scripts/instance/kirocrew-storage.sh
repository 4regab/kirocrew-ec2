#!/bin/bash
# ---------------------------------------------------------------------------
# kirocrew-storage.sh
#
# Attaches the persistent data volume to THIS instance and mounts it at the
# application user's home directory. Runs on EVERY boot (not from user-data,
# which only ever runs once per instance and so would not survive a reboot).
#
# Safety properties, in order of importance:
#   1. NEVER formats. If the filesystem UUID does not match the configured one
#      it aborts. A wrong or blank disk can therefore never be initialised.
#   2. REFUSES to force-detach the volume from an instance that is still
#      running/pending/stopping/stopped. Only a terminated or shutting-down
#      holder is treated as safe to steal from. This is what prevents a second
#      instance from ripping the volume out from under a live one.
#   3. Verifies sentinel paths after mounting. If the expected application
#      state is absent it unmounts and exits non-zero, so the app is never
#      started against an empty or unexpected disk.
#   4. Idempotent. If already mounted it exits 0 immediately.
#
# Exit non-zero triggers OnFailure=kirocrew-selfheal.service.
# ---------------------------------------------------------------------------
set -uo pipefail

CONFIG="${KIROCREW_CONFIG:-/etc/kirocrew/config.env}"
[ -r "$CONFIG" ] || { echo "FATAL: cannot read $CONFIG"; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

: "${DATA_VOLUME_ID:?}" "${DATA_VOLUME_FS_UUID:?}" "${MOUNT_POINT:?}"
: "${ATTACH_DEVICE:?}" "${APP_USER:?}" "${APP_SENTINEL_PATHS:?}"

VOL_SERIAL="${DATA_VOLUME_ID//-/}"   # EBS exposes the id without the dash as the NVMe serial
BYID="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOL_SERIAL}"
ATTACH_TIMEOUT="${ATTACH_TIMEOUT:-600}"

log() { echo "[kirocrew-storage] $*"; logger -t kirocrew-storage "$*"; }

# --- instance identity via IMDSv2 -----------------------------------------
TOKEN="$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
          -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' 2>/dev/null || true)"
md() { curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
        "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null; }
IID="$(md instance-id)"
AZ_NOW="$(md placement/availability-zone)"
export AWS_DEFAULT_REGION="${AZ_NOW%?}"
[ -n "$IID" ] || { log "FATAL: could not read instance id from IMDS"; exit 1; }
log "instance=$IID az=$AZ_NOW region=$AWS_DEFAULT_REGION volume=$DATA_VOLUME_ID"

# --- already mounted? ------------------------------------------------------
if findmnt -M "$MOUNT_POINT" >/dev/null 2>&1; then
  log "already mounted from $(findmnt -no SOURCE -M "$MOUNT_POINT") - nothing to do"
  exit 0
fi

# --- attach, with retries ---------------------------------------------------
DEADLINE=$(( $(date +%s) + ATTACH_TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  STATE="$(aws ec2 describe-volumes --volume-ids "$DATA_VOLUME_ID" \
            --query 'Volumes[0].State' --output text 2>/dev/null || echo unknown)"
  HOLDER="$(aws ec2 describe-volumes --volume-ids "$DATA_VOLUME_ID" \
            --query 'Volumes[0].Attachments[0].InstanceId' --output text 2>/dev/null || echo None)"
  log "volume state=$STATE holder=$HOLDER"

  [ "$HOLDER" = "$IID" ] && { log "attached to me"; break; }

  if [ "$STATE" = "available" ]; then
    if aws ec2 attach-volume --volume-id "$DATA_VOLUME_ID" --instance-id "$IID" \
         --device "$ATTACH_DEVICE" >/dev/null 2>&1; then
      log "attach requested"
    else
      log "attach call failed, will retry"
    fi
  elif [ "$STATE" = "in-use" ] && [ "$HOLDER" != "None" ] && [ -n "$HOLDER" ]; then
    OTHER="$(aws ec2 describe-instances --instance-ids "$HOLDER" \
              --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)"
    log "held by $HOLDER which is $OTHER"
    case "$OTHER" in
      terminated|shutting-down)
        log "holder is gone - force detaching"
        aws ec2 detach-volume --volume-id "$DATA_VOLUME_ID" --force >/dev/null 2>&1 || true
        ;;
      running|pending|stopping|stopped)
        log "REFUSING to steal volume from a live instance ($HOLDER is $OTHER)"
        ;;
    esac
  fi
  sleep 10
done

# --- wait for the block device --------------------------------------------
# Resolve by EBS serial, never by the requested device name: on Nitro the
# kernel renames /dev/sdf to /dev/nvmeXn1 with a non-deterministic index.
for _ in $(seq 1 60); do
  udevadm settle 2>/dev/null || true
  [ -e "$BYID" ] && break
  sleep 2
done
[ -e "$BYID" ] || { log "FATAL: $BYID never appeared"; exit 1; }
DEV="$(readlink -f "$BYID")"
log "device=$DEV"

# --- the hard safety gate: correct filesystem, or nothing -----------------
UUID="$(blkid -s UUID -o value "$DEV" 2>/dev/null || true)"
if [ "$UUID" != "$DATA_VOLUME_FS_UUID" ]; then
  log "FATAL: filesystem UUID mismatch (got '$UUID', want '$DATA_VOLUME_FS_UUID')"
  log "NOT formatting and NOT mounting. Aborting."
  exit 1
fi

mkdir -p "$MOUNT_POINT"
mount "$DEV" "$MOUNT_POINT" || { log "FATAL: mount failed"; exit 1; }

# --- verify the app state really is on there ------------------------------
for p in $APP_SENTINEL_PATHS; do
  if [ ! -e "$MOUNT_POINT/$p" ]; then
    log "FATAL: expected state missing: $MOUNT_POINT/$p - unmounting and aborting"
    umount "$MOUNT_POINT" || true
    exit 1
  fi
done

chown "$APP_USER":"$APP_USER" "$MOUNT_POINT" || true
restorecon -R "$MOUNT_POINT" 2>/dev/null || true
log "mounted $DEV at $MOUNT_POINT and verified state OK"
exit 0
