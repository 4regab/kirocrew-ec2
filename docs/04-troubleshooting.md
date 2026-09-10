# 04 — Troubleshooting

Start here, always:

```bash
aws autoscaling describe-auto-scaling-groups --region $AWS_REGION \
  --auto-scaling-group-names $ASG_NAME --output json

aws autoscaling describe-scaling-activities --region $AWS_REGION \
  --auto-scaling-group-name $ASG_NAME --max-items 5 --output json

aws ec2 describe-volumes --region $AWS_REGION --volume-ids $DATA_VOLUME_ID --output json
```

Then, on the instance:

```bash
systemctl is-active kirocrew-storage kirocrew kirocrew-tmux kirocrew-spot-watch
journalctl -u kirocrew-storage --no-pager -n 40
```

---

## The application is not running and the instance looks healthy

Almost always the storage unit failed and `Requires=` correctly blocked the
application. That is the design working, not a bug: it refuses to start against
missing state rather than writing fresh, empty state over nothing.

```bash
systemctl status kirocrew-storage --no-pager
journalctl -u kirocrew-storage --no-pager -n 40
```

Match the log line to a cause:

| Log line | Cause | Fix |
|---|---|---|
| `REFUSING to steal volume from a live instance (i-… is running)` | Another instance still holds the volume | Expected during a rehearsal. Otherwise you have a duplicate — find it, confirm which one should live, terminate the other |
| `FATAL: filesystem UUID mismatch (got '…', want '…')` | Wrong disk attached, or `DATA_VOLUME_FS_UUID` is wrong in the config | Check `blkid`. **Never** "fix" this by formatting — a mismatch usually means the right disk is somewhere else |
| `FATAL: filesystem UUID mismatch (got '', want …)` | Blank disk — likely a new volume created from a launch template block device mapping | Remove the data volume from the launch template's `BlockDeviceMappings`. It must be attached via the API, not the template |
| `FATAL: /dev/disk/by-id/… never appeared` | Attach succeeded but the device did not surface | Check `dmesg`; verify the volume and instance are in the same AZ |
| `FATAL: expected state missing: …` | Volume mounted, but application state is absent | You mounted the wrong volume, or the migration never completed. Check the sentinel paths in `APP_SENTINEL_PATHS` |
| `attach call failed, will retry` repeatedly | IAM | Confirm `ec2:AttachVolume` covers **both** the volume ARN and `instance/*` |

## The instance keeps getting replaced in a loop

Self-heal is doing its job against a permanent fault. Every ~11 minutes: storage
times out, marks Unhealthy, ASG relaunches.

```bash
journalctl -u kirocrew-selfheal --no-pager -n 20
aws autoscaling describe-scaling-activities --auto-scaling-group-name $ASG_NAME --max-items 10
```

Break the loop first, then diagnose calmly:

```bash
aws autoscaling update-auto-scaling-group --auto-scaling-group-name $ASG_NAME \
  --min-size 0 --desired-capacity 0
```

Usual permanent causes: the volume was deleted; the volume is in a different AZ
from the subnet; `DATA_VOLUME_ID` is wrong in the AMI's config.

## No instance is launching at all

```bash
aws autoscaling describe-scaling-activities --auto-scaling-group-name $ASG_NAME \
  --max-items 5 --output json
```

`Description` and `StatusMessage` name the cause.

- **Insufficient capacity across all pools.** The accepted risk of single-AZ
  spot. The ASG keeps retrying by itself. To force it now: add more instance
  types to the overrides, or temporarily set `OnDemandBaseCapacity: 1`.
- **`Invalid launch template`** — an override references an instance type not
  offered in your AZ. Re-check with `describe-instance-type-offerings`.
- **Architecture mismatch** — an override does not match the AMI's architecture.
  Instances launch and never boot.
- **vCPU quota exceeded** — check Service Quotas for standard spot instance
  requests.

## Volume stuck attaching or detaching

```bash
aws ec2 describe-volumes --volume-ids $DATA_VOLUME_ID \
  --query 'Volumes[0].Attachments' --output json
```

If the holder is genuinely terminated and it is still `attaching`/`detaching`
after several minutes:

```bash
aws ec2 detach-volume --volume-id $DATA_VOLUME_ID --force
```

`--force` skips the flush. Safe when the holder is already gone; risks losing
unflushed writes otherwise. Confirm the holder's state before using it — the boot
script applies exactly that rule automatically.

## Mount fails with "wrong fs type, bad superblock"

Duplicate filesystem UUID. Check `dmesg`:

```
XFS: Filesystem has duplicate UUID <uuid> - can't mount
```

You have two disks with one UUID, which means the data volume was created from
a snapshot sharing an ancestor with the root volume. `-o nouuid` gets you mounted
now, but leaves the boot-time wrong-root hazard described in
`01-architecture.md`. The real fix is a data volume with its own UUID: create
fresh, format, migrate. If you must keep the disk as-is, `xfs_admin -U generate`
on the unmounted filesystem rewrites the UUID — note this breaks that volume's
own `/etc/fstab`, so it will no longer boot standalone.

## Application starts, then crash-loops

Not a storage problem — the mount succeeded and the app is running.

```bash
systemctl show kirocrew -p NRestarts -p ExecMainStatus
journalctl -u kirocrew --no-pager -n 100
```

The instance is genuinely healthy, so neither the ASG nor self-heal will act,
and that is deliberate: replacing the instance cannot fix bad config or bad
code, and would only thrash. The CloudWatch alarm will not fire either, since
`GroupInServiceInstances` stays at 1. This gap is intentional and is why you
still need application-level alerting.

## Nothing has restarted after three quick crashes

Symptom of the systemd default that this design removes. Confirm:

```bash
systemctl show kirocrew -p StartLimitIntervalSec -p StartLimitBurst
```

`StartLimitIntervalSec=0` disables the give-up behaviour. If it is non-zero, your
unit file is not the one from this repo. Immediate unblock:
`systemctl reset-failed kirocrew`.

## `tmux attach -t kiro` says no such session

```bash
systemctl status kirocrew-tmux --no-pager
systemctl restart kirocrew-tmux
```

The tmux unit requires the application unit, so if the app is down the session
will not exist. Cosmetic only — `journalctl -u kirocrew -f` always works.

## Agents or subprocesses fail to spawn

If the application uses `systemd-run --user`, it needs a running user manager:

```bash
ls -la /run/user/<uid>          # must exist
loginctl show-user <user> | grep -i linger    # must be Linger=yes
systemctl status user@<uid>.service
```

Missing linger in the AMI is the usual cause. Also check the cgroup pids limit
if forks are being rejected:

```bash
systemctl --user show <slice> -p TasksMax -p TasksCurrent
journalctl -k | grep 'fork rejected'
```

## SSM Session Manager will not connect

```bash
aws ssm describe-instance-information --region $AWS_REGION --output json
```

If the instance is absent: no instance profile, no `AmazonSSMManagedInstanceCore`,
no outbound internet path, or the agent is in a long backoff after earlier
credential failures. The last one is common after attaching a profile to an
already-running instance — it does not retry promptly:

```bash
sudo systemctl restart amazon-ssm-agent
```

## Verifying there are no duplicates or orphans

```bash
aws ec2 describe-instances --region $AWS_REGION \
  --filters Name=instance-state-name,Values=running,pending --output json

aws ec2 describe-volumes --region $AWS_REGION \
  --filters Name=status,Values=available --output json
```

Expect exactly one running instance, and no unexpected `available` volumes
beyond the rollbacks you chose to keep.
