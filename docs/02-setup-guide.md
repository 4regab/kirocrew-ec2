# 02 — Setup guide

Follow in order. Steps 1-7 are non-disruptive and can be done while the existing
service keeps running. Step 8 is the only outage.

Throughout, `$VAR` refers to a value in your `config.env`.

> **Before you start, take a snapshot** if you are migrating an existing
> instance. Everything after step 8 involves terminating it, and the snapshot is
> your only complete rollback. It costs about $0.05/GiB-month for used blocks and
> can be deleted once you are satisfied.
>
> ```bash
> aws ec2 create-snapshot --region $AWS_REGION --volume-id <existing-volume> \
>   --query SnapshotId --output text
> aws ec2 wait snapshot-completed --region $AWS_REGION --snapshot-ids <snap-id>
> ```

---

## Step 1 — Inventory what you are migrating

Skip if deploying fresh. Otherwise you need to know exactly what the application
depends on, because the AMI has to reproduce it.

```bash
# Where is state, and is it on the root volume?
lsblk -o NAME,SERIAL,UUID,FSTYPE,SIZE,MOUNTPOINT
df -hT
findmnt /

# What did you install by hand after the AMI was built?
# dnf transactions dated after the instance launch are yours.
dnf history list | head -20
dnf repoquery --userinstalled --qf '%{name}' | sort

# How is the app started today, and is it supervised?
systemctl list-unit-files --state=enabled --no-pager | grep -i <app>
systemctl status <app> --no-pager
pgrep -af <app>
cat /proc/<pid>/cgroup          # reveals a session scope vs a service

# Does the app need a systemd user manager? (linger must be on)
loginctl show-user $USER | grep -i linger
id $USER                         # note the extra groups

# Non-default system config to reproduce
ls -la /etc/systemd/system/
ls /etc/sysctl.d/ /etc/security/limits.d/
getenforce
```

Two findings commonly change the plan:

- **State is on the root volume.** Then you need step 3 — a root volume cannot be
  carried to a replacement.
- **The app is not actually supervised.** A `tmux` + `while true` loop tied to an
  SSH session is common. It will not survive a reboot.

Also measure real memory and CPU use (`free -m`, `uptime`) before choosing
instance types. Do not assume the current size is right in either direction.

## Step 2 — IAM role and instance profile

```bash
aws iam create-role --role-name $IAM_ROLE_NAME \
  --assume-role-policy-document file://templates/iam-trust-policy.json

aws iam attach-role-policy --role-name $IAM_ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile --instance-profile-name $INSTANCE_PROFILE_NAME
aws iam add-role-to-instance-profile \
  --instance-profile-name $INSTANCE_PROFILE_NAME --role-name $IAM_ROLE_NAME
```

The narrow EBS/autoscaling policy is added in step 4, once the volume id exists.

`AmazonSSMManagedInstanceCore` gives you Session Manager, which is worth having:
replacement instances get a new public IP every time, and SSM does not care.

> **If you are attaching a profile to an already-running instance** to get SSM
> access, the agent may not pick it up for a long time — it backs off after
> repeated credential failures. Force it with
> `sudo systemctl restart amazon-ssm-agent`.

## Step 3 — Create and format the data volume

```bash
aws ec2 create-volume --region $AWS_REGION --availability-zone $AZ \
  --size $DATA_VOLUME_SIZE_GIB --volume-type gp3 \
  --tag-specifications 'ResourceType=volume,Tags=[{Key=Name,Value=kirocrew-data}]' \
  --query VolumeId --output text

aws ec2 attach-volume --region $AWS_REGION --volume-id $DATA_VOLUME_ID \
  --instance-id <existing-instance> --device $ATTACH_DEVICE
```

Attaching a second disk to a running instance is non-disruptive.

Now format it — **on the instance**, with guards. Never run a bare `mkfs`:

```bash
BYID=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${DATA_VOLUME_ID//-/}
DEV=$(readlink -f $BYID)

# Guard 1: is this really the new volume?
[ "$(lsblk -dno SERIAL $DEV)" = "${DATA_VOLUME_ID//-/}" ] || exit 1
# Guard 2: is it the disk holding / ?
[ "$DEV" != "/dev/$(lsblk -no pkname $(findmnt -no SOURCE /))" ] || exit 1
# Guard 3: is it genuinely blank?
[ -z "$(blkid $DEV)" ] || exit 1
[ -z "$(lsblk -no NAME $DEV | tail -n +2)" ] || exit 1

sudo mkfs.xfs -L "$DATA_VOLUME_LABEL" "$DEV"   # XFS labels: max 12 chars
blkid -s UUID -o value "$DEV"                  # ← put this in DATA_VOLUME_FS_UUID
```

Record that UUID in `config.env`. It is the value the boot script checks before
it will mount anything, and it must differ from your root volume's UUID —
confirm with `blkid`.

## Step 4 — Narrow the IAM policy to this volume

Fill `REGION`, `ACCOUNT_ID`, `DATA_VOLUME_ID` and `ASG_NAME` into
`templates/iam-instance-policy.json` (and remove the `_comment` keys), then:

```bash
aws iam put-role-policy --role-name $IAM_ROLE_NAME \
  --policy-name kirocrew-ebs-attach \
  --policy-document file://templates/iam-instance-policy.json
```

Verify the explicit Deny works — this is worth doing, since the machine may run
agents that execute arbitrary code and inherit this role:

```bash
aws ec2 delete-volume --volume-id $DATA_VOLUME_ID --dry-run   # must be denied
```

## Step 5 — Bulk copy the data (application still running)

```bash
sudo KIROCREW_CONFIG=/path/to/config.env ./scripts/migrate-home.sh --pass1
```

Reads the home directory, writes only to the new volume. Expect `rsync_exit=0`,
or `23`/`24` if files changed mid-copy — both fine at this stage.

Do **not** run pass 2 yet. State written between the passes would be lost;
pass 2 belongs inside the cutover window.

## Step 6 — Build the AMI on a throwaway instance

Build on a *separate* instance so the live one is never rebooted.

```bash
aws ec2 run-instances --region $AWS_REGION --image-id $BASE_AMI \
  --instance-type t3.small --subnet-id $SUBNET_ID \
  --security-group-ids $SECURITY_GROUP_ID \
  --iam-instance-profile Name=$INSTANCE_PROFILE_NAME \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=ami-builder}]' \
  --query 'Instances[0].InstanceId' --output text
```

Copy `config.env`, `scripts/build-ami.sh`, `scripts/instance/` and
`scripts/systemd/` to `/tmp/kirocrew-build/` on the builder, then run it as
root. It installs packages, drops in scripts and units, and **enables but does
not start** them.

Verify before imaging:

```bash
systemctl is-enabled kirocrew-storage kirocrew kirocrew-tmux kirocrew-spot-watch
# expect: enabled x4
systemctl is-active  kirocrew-storage kirocrew kirocrew-tmux kirocrew-spot-watch
# expect: inactive x4  ← must NOT be running on the builder
systemctl show kirocrew-storage -p OnFailure
# expect: OnFailure=kirocrew-selfheal.service
systemctl show kirocrew-selfheal -p UnitFileState
# expect: static
```

Prove the self-heal chain actually fires, rather than assuming it:

```bash
sudo cp /usr/local/sbin/kirocrew-storage.sh /root/bak
sudo sh -c 'printf "#!/bin/bash\nexit 1\n" > /usr/local/sbin/kirocrew-storage.sh'
sudo systemctl start kirocrew-storage; sleep 10
sudo journalctl -u kirocrew-selfheal --no-pager -n 10   # must show it ran
sudo cp /root/bak /usr/local/sbin/kirocrew-storage.sh   # RESTORE
sudo systemctl reset-failed kirocrew-storage kirocrew-selfheal
```

Then image it:

```bash
aws ec2 stop-instances --region $AWS_REGION --instance-ids <builder>
aws ec2 wait instance-stopped --region $AWS_REGION --instance-ids <builder>
aws ec2 create-image --region $AWS_REGION --instance-id <builder> \
  --name kirocrew-gateway-v1 --no-reboot --query ImageId --output text
aws ec2 wait image-available --region $AWS_REGION --image-ids <ami>
aws ec2 terminate-instances --region $AWS_REGION --instance-ids <builder>
```

Record the AMI id in `BUILT_AMI`.

## Step 7 — Launch template, ASG, and a dress rehearsal

Fill in `templates/launch-template.json` and `templates/asg.json`, strip the
`_comment` keys, then:

```bash
aws ec2 create-launch-template --region $AWS_REGION \
  --cli-input-json file://templates/launch-template.json

# Confirm every instance type actually exists in your AZ before referencing them
aws ec2 describe-instance-type-offerings --region $AWS_REGION \
  --location-type availability-zone --filters Name=location,Values=$AZ \
  --query 'InstanceTypeOfferings[].InstanceType' --output text | tr '\t' '\n' | sort

aws autoscaling create-auto-scaling-group --region $AWS_REGION \
  --cli-input-json file://templates/asg.json     # DesiredCapacity 0
```

**Rehearse on a clone**, not on your real volume:

```bash
aws ec2 create-snapshot --volume-id $DATA_VOLUME_ID --query SnapshotId --output text
aws ec2 create-volume --availability-zone $AZ --snapshot-id <snap> \
  --volume-type gp3 --query VolumeId --output text

aws ec2 run-instances --launch-template LaunchTemplateName=$LAUNCH_TEMPLATE_NAME \
  --instance-type t3.small --subnet-id $SUBNET_ID \
  --query 'Instances[0].InstanceId' --output text
```

Four things to confirm on that test instance:

1. **The refusal guard fires.** Its storage unit should log
   `REFUSING to steal volume from a live instance (… is running)`. This is the
   most important check in the whole setup.
2. **The application did not start** — `systemctl is-active kirocrew` is
   `inactive`, because `Requires=` blocked it. No duplicate connection to your
   upstream service, no start against empty state.
3. **`/run/user/<uid>` exists**, proving linger works from the AMI.
4. Then point a *copy* of the storage script at the clone volume id and run it.
   Confirm it mounts, and that the runtime resolves from the mounted volume:

```bash
sudo -u $APP_USER $APP_EXEC --version
sudo -u $APP_USER /home/$APP_USER/<venv>/bin/python3 --version
```

Do **not** start the real application on the test instance if it connects to an
upstream service that permits only one session per credential — it would kick
your live instance offline.

Clean up: terminate the test instance, delete the clone volume and its snapshot.

## Step 8 — Cutover (the only outage)

Budget **10 minutes**. Two checkpointed stages, so you can stop between them.

### 8a — Stop the application

Order matters. Kill any respawn loop **first**, or it will restart the app
underneath you:

```bash
pgrep -af 'bash -c while true'                    # find the loop
sudo pkill -9 -f 'bash -c while true'             # matches the loop, not tmux
sudo pkill -TERM -f '<app process pattern>'       # then graceful stop
# wait for exit, SIGKILL only if it overruns
sudo -u $APP_USER tmux kill-session -t $TMUX_SESSION
ss -tlnp | grep <port>                            # confirm the port is released
```

### 8b — Final delta copy, verify, unmount, switch

```bash
sudo KIROCREW_CONFIG=/path/to/config.env ./scripts/migrate-home.sh --pass2
```

That script refuses to continue unless every critical file checksum matches, and
unmounts only after verifying. It prints `SAFE TO DETACH`.

Consider also running `diff -rq $SRC $STAGE`. On ~200k files it adds about four
minutes — the reason a 10-minute budget is realistic rather than 5. Dangling
runtime symlinks (browser singleton locks and similar) will show up as
unreadable; that is normal.

```bash
aws ec2 detach-volume --region $AWS_REGION --volume-id $DATA_VOLUME_ID
aws ec2 wait volume-available --region $AWS_REGION --volume-ids $DATA_VOLUME_ID

# The old volume survives if DeleteOnTermination=false - check first, it is a rollback
aws ec2 terminate-instances --region $AWS_REGION --instance-ids <old-instance>

aws autoscaling update-auto-scaling-group --region $AWS_REGION \
  --auto-scaling-group-name $ASG_NAME --min-size 1 --max-size 1 --desired-capacity 1
```

### 8c — Verify the replacement

```bash
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME
# expect LifecycleState=InService, HealthStatus=Healthy

# then on the new instance:
systemctl is-active kirocrew-storage kirocrew kirocrew-tmux kirocrew-spot-watch
journalctl -u kirocrew-storage --no-pager -n 10   # "mounted … and verified state OK"
findmnt $MOUNT_POINT
md5sum $MOUNT_POINT/<critical files>              # compare with pre-cutover values
systemctl show kirocrew -p MainPID -p NRestarts -p Restart
```

Finally confirm the service is genuinely reachable from the outside — the one
thing no amount of local checking proves.

## Step 9 — Prove replacement works

Do not infer this; test it.

```bash
aws autoscaling terminate-instance-in-auto-scaling-group \
  --instance-id <current> --no-should-decrement-desired-capacity
```

Time how long until the service is back. Confirm afterwards: the volume
re-attached to the new instance, data is current, no orphaned root volumes, and
at no point did two instances exist.

## Step 10 — Alarm and cleanup

```bash
aws sns create-topic --name kirocrew-alerts --query TopicArn --output text
aws sns subscribe --topic-arn <arn> --protocol email --notification-endpoint $ALARM_EMAIL
# confirm via the email you receive

aws cloudwatch put-metric-alarm --alarm-name kirocrew-gateway-down \
  --namespace AWS/AutoScaling --metric-name GroupInServiceInstances \
  --dimensions Name=AutoScalingGroupName,Value=$ASG_NAME \
  --statistic Minimum --period 60 --evaluation-periods 5 \
  --threshold 1 --comparison-operator LessThanThreshold \
  --treat-missing-data breaching --alarm-actions <arn>
```

This is the backstop for the failure mode nothing else catches: capacity
unavailable across every instance type in your AZ.

Once you are satisfied — days, not minutes — delete the old volume and the
pre-migration snapshot, and deregister superseded AMIs with their snapshots.
Keep them until then; they are your rollback.
