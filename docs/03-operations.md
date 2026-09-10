# 03 — Operations

## Finding the current instance

Replacement instances get a new id and a new public IP every time, so never
hard-code either.

```bash
aws autoscaling describe-auto-scaling-groups --region $AWS_REGION \
  --auto-scaling-group-names $ASG_NAME \
  --query 'AutoScalingGroups[0].Instances[].[InstanceId,InstanceType,LifecycleState,HealthStatus]' \
  --output table
```

Connect without caring about the IP:

```bash
aws ssm start-session --region $AWS_REGION --target <instance-id>
```

## Watching the application

```bash
tmux attach -t kiro          # live journal tail, recreated on every boot
                             # detach with Ctrl-B then D
```

This is a **read-only view**, not an interactive pane — the application runs
under systemd, not inside tmux. To act on it, use systemctl:

```bash
journalctl -u kirocrew -f                # same stream, without tmux
journalctl -u kirocrew --since '1 hour ago' --no-pager
journalctl -u kirocrew-storage -n 30     # boot-time attach/mount trace
journalctl -u kirocrew-spot-watch -n 20  # interruption watcher
journalctl -u kirocrew-selfheal -n 20    # only non-empty if storage has failed

sudo systemctl restart kirocrew
sudo systemctl status kirocrew --no-pager
```

Logs survive application restarts, which the old `while true` loop could not do.

## Deploying application code

Code and state live on the data volume, so **no AMI rebuild is needed**:

```bash
aws ssm start-session --target <instance-id>
cd ~/<project> && git pull
sudo systemctl restart kirocrew
journalctl -u kirocrew -f          # watch it come back
```

## Rebuilding the AMI

Only needed when OS packages, toolchain versions, the instance scripts or the
systemd units change.

1. Launch a builder from the **current** AMI (not the stock base) so you only
   apply your delta
2. Apply changes, then run the same verification block from setup step 6 —
   including forcing a storage failure to confirm `OnFailure` still fires
3. Stop, `create-image --no-reboot`, wait, terminate the builder
4. New launch template version, and make it the default:

```bash
aws ec2 create-launch-template-version --region $AWS_REGION \
  --launch-template-name $LAUNCH_TEMPLATE_NAME --source-version '$Latest' \
  --version-description "what changed" \
  --launch-template-data '{"ImageId":"<new-ami>"}'

aws ec2 modify-launch-template --region $AWS_REGION \
  --launch-template-name $LAUNCH_TEMPLATE_NAME --default-version <n>
```

5. Roll it out. The ASG only picks up a new AMI when it launches an instance, so
   nothing changes until you force a replacement:

```bash
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id <current> --no-should-decrement-desired-capacity
```

That costs one outage window. Batch AMI changes rather than rolling out singly.

> If your ASG references `Version: "$Latest"`, a new default version is picked up
> automatically on the next launch — including an unplanned one. Pin a specific
> version number if you would rather control exactly when new AMIs go live.

## Resizing

**Instance type.** Edit the `Overrides` list in the ASG's mixed instances
policy. Every entry must match the AMI architecture and have enough memory.
Prefer non-burstable families for sustained-CPU workloads: burstable types
throttle to their baseline once credits are exhausted, which on a busy box can
be a large and confusing slowdown for a few percent saved.

**Data volume.** gp3 grows online:

```bash
aws ec2 modify-volume --region $AWS_REGION --volume-id $DATA_VOLUME_ID --size 80
# then, on the instance:
sudo xfs_growfs $MOUNT_POINT
```

XFS **cannot shrink**. Oversize deliberately rather than planning to reduce.

## Planned maintenance

To take the service down without the ASG fighting you:

```bash
aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_NAME \
  --min-size 0 --desired-capacity 0
# ... do the work ...
aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_NAME \
  --min-size 1 --desired-capacity 1
```

To reboot the current instance, just reboot it. The storage unit runs again on
boot and is idempotent, so the volume re-mounts and the application restarts —
this is precisely why the logic is a systemd unit rather than user-data.

## Backups

The design protects against instance loss, **not** against data loss. Nothing
here guards against a bad write, a bad deploy, or a deleted file. Add scheduled
snapshots:

```bash
aws dlm create-lifecycle-policy --region $AWS_REGION \
  --description "kirocrew data daily" --state ENABLED \
  --execution-role-arn arn:aws:iam::$ACCOUNT_ID:role/AWSDataLifecycleManagerDefaultRole \
  --policy-details '{
    "ResourceTypes":["VOLUME"],
    "TargetTags":[{"Key":"Name","Value":"kirocrew-data"}],
    "Schedules":[{
      "Name":"daily","CreateRule":{"Interval":24,"IntervalUnit":"HOURS","Times":["03:00"]},
      "RetainRule":{"Count":7},"CopyTags":true}]}'
```

Roughly $0.05/GiB-month for changed blocks. Cheap relative to what it protects.

## Recommended follow-ups

**Encrypt the data volume.** It holds credentials and application state. EBS
cannot encrypt in place; the migration is snapshot → copy-snapshot with
encryption → new volume → swap during a maintenance window.

**Set a default region.** Every command here needs `--region`, because the data
volume's region often is not the CLI default. `export AWS_DEFAULT_REGION` in your
shell to avoid a surprise in the wrong region.

## Emergency: bring the service up by hand

If the ASG path is broken and you need the service running now:

```bash
aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_NAME \
  --min-size 0 --desired-capacity 0        # stop it fighting you

aws ec2 run-instances --region $AWS_REGION \
  --launch-template LaunchTemplateName=$LAUNCH_TEMPLATE_NAME \
  --subnet-id $SUBNET_ID --query 'Instances[0].InstanceId' --output text
```

A manually launched instance still attaches and mounts the volume normally. The
self-heal unit deliberately does nothing outside an ASG, so it will not try to
terminate your rescue instance.
