#!/bin/bash
# ---------------------------------------------------------------------------
# kirocrew-spot-watch.sh
#
# Polls IMDS for the two signals EC2 gives before taking a spot instance away,
# then drains cleanly so the replacement can attach the data volume straight
# away instead of waiting out a force-detach.
#
#   /latest/meta-data/spot/instance-action            2-minute termination notice
#   /latest/meta-data/events/recommendations/rebalance  earlier "capacity at risk" hint
#
# Draining does four things in order: stop the app, sync, unmount, detach.
# Unmounting before the instance dies means the next mount finds a clean XFS
# log rather than replaying a journal.
#
# Set DRY_RUN=1 to log what it would do without touching anything.
# ---------------------------------------------------------------------------
set -uo pipefail

CONFIG="${KIROCREW_CONFIG:-/etc/kirocrew/config.env}"
[ -r "$CONFIG" ] || { echo "FATAL: cannot read $CONFIG"; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

: "${DATA_VOLUME_ID:?}" "${MOUNT_POINT:?}"
DRY_RUN="${DRY_RUN:-0}"
POLL_SECONDS="${POLL_SECONDS:-5}"

log() { logger -t kirocrew-spot "$*"; echo "[kirocrew-spot] $*"; }

TOKEN=""
refresh_token() {
  TOKEN="$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
            -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' 2>/dev/null || true)"
}
http_code() {
  curl -sS -o /dev/null -w '%{http_code}' \
    -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/$1" 2>/dev/null || echo 000
}

refresh_token
IID="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
AZ_NOW="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || true)"
export AWS_DEFAULT_REGION="${AZ_NOW%?}"
log "watching (instance=$IID dry_run=$DRY_RUN)"

TICK=0
while true; do
  TICK=$((TICK + 1))
  # IMDS tokens expire; refresh roughly every 4 minutes at a 5s poll.
  [ $((TICK % 50)) -eq 1 ] && refresh_token

  ACTION="$(http_code spot/instance-action)"
  REBAL="$(http_code events/recommendations/rebalance)"

  if [ "$ACTION" = "200" ] || [ "$REBAL" = "200" ]; then
    log "INTERRUPTION SIGNAL action=$ACTION rebalance=$REBAL - draining"

    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN set - would stop the app, unmount $MOUNT_POINT and detach $DATA_VOLUME_ID"
      sleep 15
      continue
    fi

    systemctl stop kirocrew-tmux.service 2>/dev/null || true
    systemctl stop kirocrew.service 2>/dev/null || true
    sync

    for i in 1 2 3 4 5; do
      if umount "$MOUNT_POINT" 2>/dev/null; then log "unmounted $MOUNT_POINT"; break; fi
      log "umount attempt $i failed"
      sleep 2
      if [ "$i" = "5" ]; then
        # Last resort. The instance is about to disappear regardless; a lazy
        # unmount plus the sync above is better than leaving it mounted.
        umount -l "$MOUNT_POINT" 2>/dev/null || true
        log "lazy unmount"
      fi
    done
    sync

    if aws ec2 detach-volume --volume-id "$DATA_VOLUME_ID" >/dev/null 2>&1; then
      log "detach requested"
    else
      log "detach call failed - the replacement will force-detach once this instance terminates"
    fi

    log "drain complete"
    exit 0
  fi

  sleep "$POLL_SECONDS"
done
