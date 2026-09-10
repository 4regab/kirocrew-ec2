#!/bin/bash
# ---------------------------------------------------------------------------
# migrate-home.sh
#
# Copies an existing home directory onto the new data volume, in two passes.
#
#   PASS 1 (--pass1)  application still RUNNING. Moves the bulk. Open files may
#                     be copied inconsistently, which is fine - pass 2 fixes it.
#                     Non-disruptive: reads the source, writes only the volume.
#
#   PASS 2 (--pass2)  application STOPPED. Delta only, so it takes seconds.
#                     This is the consistent copy. Run it inside the cutover
#                     window, immediately before detaching, so that state
#                     written between the passes is not lost.
#
# Splitting it this way is what keeps the outage short: on a 7 GB home the bulk
# pass took ~2 minutes and the delta pass ~10 seconds.
#
# Nothing here ever writes to or deletes from the SOURCE.
#
# Usage:
#   ./migrate-home.sh --pass1
#   ./migrate-home.sh --pass2
#   ./migrate-home.sh --verify
# ---------------------------------------------------------------------------
set -uo pipefail

CONFIG="${KIROCREW_CONFIG:-/etc/kirocrew/config.env}"
[ -r "$CONFIG" ] || { echo "FATAL: cannot read $CONFIG"; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

SRC="${MOUNT_POINT:?}"                 # the live home directory
STAGE="${STAGE_MOUNT:-/mnt/kcdata}"    # where the new volume is staged
VOL_SERIAL="${DATA_VOLUME_ID//-/}"
BYID="/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOL_SERIAL}"
CRIT="${CRITICAL_FILES:-.kiro/crew/config.json .kiro/crew/.env .kiro/crew/token_signing.key .kiro/crew/.local_secret .kiro/crew/memory.db}"

die() { echo "FATAL: $*"; exit 1; }

mount_stage() {
  [ -e "$BYID" ] || die "$BYID not found - is the data volume attached?"
  local dev uuid
  dev="$(readlink -f "$BYID")"
  uuid="$(blkid -s UUID -o value "$dev")"
  [ "$uuid" = "$DATA_VOLUME_FS_UUID" ] || die "wrong volume: uuid $uuid != $DATA_VOLUME_FS_UUID"
  mkdir -p "$STAGE"
  findmnt -M "$STAGE" >/dev/null 2>&1 || mount "$dev" "$STAGE"
  # Guard: staging the volume ON TOP of the source would be catastrophic.
  [ "$(findmnt -no SOURCE --target "$SRC")" != "$(findmnt -no SOURCE --target "$STAGE")" ] \
    || die "source and destination are the same filesystem"
  echo "staged $dev at $STAGE"
}

do_rsync() {
  echo "=== rsync $1 ==="; date -u
  # -aHAX preserves hardlinks, ACLs and xattrs (which carry SELinux labels).
  # --numeric-ids avoids any uid/gid remapping surprises.
  rsync -aHAX --numeric-ids --delete --stats "$SRC/" "$STAGE/" 2>&1 | tail -14
  echo "rsync_exit=${PIPESTATUS[0]}   (0=clean, 23/24=files changed mid-copy, expected in pass 1)"
  date -u; sync
}

verify() {
  echo "=== object counts ==="
  echo "src=$(find "$SRC" -xdev | wc -l)  dst=$(find "$STAGE" -xdev | wc -l)"
  echo "=== critical file checksums ==="
  local fail=0 a b
  for f in $CRIT; do
    a="$(md5sum "$SRC/$f"   2>/dev/null | cut -d' ' -f1)"
    b="$(md5sum "$STAGE/$f" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "MATCH    $f  $a"
    else echo "MISMATCH $f  src=$a dst=$b"; fail=1; fi
  done
  echo "=== sizes ==="
  du -sh "$SRC" "$STAGE" 2>/dev/null
  echo "CRITICAL_VERIFY_FAIL=$fail"
  return "$fail"
}

case "${1:-}" in
  --pass1)
    mount_stage
    do_rsync "PASS 1 (app running, bulk)"
    verify || echo "NOTE: mismatches in pass 1 are expected for files being written"
    echo "volume left mounted at $STAGE"
    ;;
  --pass2)
    pgrep -af "$(basename "${APP_EXEC:-kirocrew}") ${APP_ARGS:-}" >/dev/null 2>&1 \
      && die "application still running - stop it before pass 2"
    mount_stage
    do_rsync "PASS 2 (app stopped, delta)"
    verify || die "critical file mismatch - NOT safe to cut over"
    echo "=== unmounting ==="
    for i in 1 2 3 4 5; do
      umount "$STAGE" 2>/dev/null && { echo "unmounted on attempt $i"; break; }
      echo "attempt $i busy:"; fuser -vm "$STAGE" 2>&1 | head -5; sleep 3
    done
    findmnt -M "$STAGE" && die "still mounted" || echo "CONFIRMED_UNMOUNTED"
    sync
    echo "SAFE TO DETACH"
    ;;
  --verify)
    mount_stage
    verify
    ;;
  *)
    echo "usage: $0 --pass1 | --pass2 | --verify"
    exit 2
    ;;
esac
