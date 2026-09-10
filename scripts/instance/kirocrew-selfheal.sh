#!/bin/bash
# ---------------------------------------------------------------------------
# kirocrew-selfheal.sh
#
# Invoked ONLY via OnFailure= from kirocrew-storage.service.
#
# Why this exists: an Auto Scaling group health check is EC2-level, not
# application-level. If the instance boots fine but the data volume cannot be
# attached, the ASG sees a perfectly healthy instance and does nothing, so you
# get a silent outage. Marking the instance Unhealthy makes the ASG scrap it
# and launch a replacement - very likely in a different capacity pool, which
# is exactly what is needed if the failure was pool-specific.
#
# Deliberately a NO-OP on instances that are not ASG members, so manual,
# rehearsal and AMI-builder instances are never affected.
#
# Requires autoscaling:SetInstanceHealth and autoscaling:DescribeAutoScalingInstances.
#
# Known limitation: if the underlying fault is permanent (for example the
# volume was deleted, or it lives in a different AZ), this will replace the
# instance on a loop, roughly every 11 minutes. That is noisy but cheap. The
# CloudWatch downtime alarm is what tells a human to step in.
# ---------------------------------------------------------------------------
set -uo pipefail

log() { logger -t kirocrew-selfheal "$*"; echo "[kirocrew-selfheal] $*"; }

TOKEN="$(curl -sS -X PUT http://169.254.169.254/latest/api/token \
          -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' 2>/dev/null || true)"
IID="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || true)"
AZ_NOW="$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || true)"
export AWS_DEFAULT_REGION="${AZ_NOW%?}"

[ -n "$IID" ] || { log "could not determine instance id - aborting"; exit 1; }
log "kirocrew-storage.service FAILED on $IID - evaluating self-heal"

ASG="$(aws autoscaling describe-auto-scaling-instances --instance-ids "$IID" \
        --query 'AutoScalingInstances[0].AutoScalingGroupName' --output text 2>/dev/null || echo None)"

if [ "$ASG" = "None" ] || [ -z "$ASG" ]; then
  log "instance is not an Auto Scaling group member - taking NO action (manual/rehearsal instance)"
  exit 0
fi

log "instance belongs to ASG '$ASG' - marking self Unhealthy"
if aws autoscaling set-instance-health --instance-id "$IID" \
     --health-status Unhealthy --no-should-respect-grace-period 2>&1; then
  log "marked Unhealthy - the ASG will terminate this instance and launch a replacement"
else
  log "FAILED to mark Unhealthy - check the autoscaling:SetInstanceHealth permission"
  exit 1
fi
