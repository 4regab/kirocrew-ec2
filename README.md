# Self-healing spot instance for an always-on gateway

This repo runs the KiroCrew Discord/Slack gateway on an EC2 spot instance. Spot
costs about a third of the on-demand price, but AWS can take the instance back
at any time. When that happens, this setup brings the gateway back by itself,
with the same data and no manual steps.

## What it does

When AWS takes the spot instance back, an Auto Scaling group (ASG) launches a
new one. The new instance attaches the same EBS data volume and mounts it as the
app user's home directory. systemd then starts the gateway, and a `tmux`
session opens so you can watch the logs.

The gateway is usually back within 3 to 8 minutes, with nobody touching it. Most
of that time goes to `restorecon -R`, which resets file security labels after
the mount. It takes longer as the number of files on the volume grows.

Before the old instance goes away, a watcher script stops the gateway, flushes
writes to disk, unmounts the volume and detaches it. This means the next
instance gets a clean disk and doesn't have to force it loose. The watcher does
this on a 2-minute interruption notice and also on a rebalance recommendation.
Read the rebalance warning in `docs/01-architecture.md` before you rely on it.

If the new instance can't attach the volume, it marks itself Unhealthy. The ASG
then replaces it, so you don't end up with an instance that looks fine while the
gateway is dead.

## What it doesn't do

It doesn't give you zero downtime. An EBS volume attaches to one instance at a
time, so there is always a gap while it moves. `docs/01-architecture.md`
explains why.

It can't ride out a capacity shortage in your Availability Zone (AZ). The volume
lives in one AZ, so every instance has to launch there too. If none of your
instance types are available in that AZ, the gateway stays down until capacity
comes back. The ASG keeps retrying on its own. This happens far more often if
the ASG allows only one instance type, because launches fail with
`UnfulfillableCapacity` until that one type frees up. List several.

It isn't right for every workload. AWS says spot is a poor fit for stateful
services that can't tolerate interruptions. This setup reduces that risk but
doesn't remove it. Read `docs/05-cost-and-tradeoffs.md` before you adopt it.

## Documentation

| Document | Read it when |
|---|---|
| [`docs/01-architecture.md`](docs/01-architecture.md) | You want to know why it is built this way |
| [`docs/02-setup-guide.md`](docs/02-setup-guide.md) | You are deploying it, either moving an existing instance or starting fresh |
| [`docs/03-operations.md`](docs/03-operations.md) | It is running and you need to read logs, deploy code, resize, or rebuild the AMI |
| [`docs/04-troubleshooting.md`](docs/04-troubleshooting.md) | Something is broken |
| [`docs/05-cost-and-tradeoffs.md`](docs/05-cost-and-tradeoffs.md) | You are deciding whether spot is worth it, picking a size, or trying to cut the bill |

## Repository layout

```
config.env.example            every deployment setting; copy it to config.env
docs/                         the five documents above
scripts/
  build-ami.sh                runs on a temporary instance and builds the AMI
  migrate-home.sh             copies an existing home directory onto the volume in two passes
  instance/
    kirocrew-storage.sh       attaches and mounts the data volume on every boot
    kirocrew-spot-watch.sh    stops the gateway and detaches the volume before shutdown
    kirocrew-selfheal.sh      marks the instance Unhealthy so the ASG replaces it
  systemd/
    kirocrew-storage.service  runs the storage script, calls self-heal if it fails
    kirocrew.service          the gateway itself, restarted whenever it exits
    kirocrew-tmux.service     the tmux session for watching logs
    kirocrew-spot-watch.service
    kirocrew-selfheal.service only runs when the storage unit fails
templates/
  iam-trust-policy.json
  iam-instance-policy.json    minimum permissions, plus a Deny on destructive actions
  launch-template.json
  asg.json
```

## What you need

- An AWS account, and the AWS CLI v2 logged in with access to EC2, Auto
  Scaling, IAM, SSM and CloudWatch.
- One subnet in the AZ where the data volume will live. It needs a route to an
  internet gateway, because the gateway connects out. Nothing needs to connect
  in.
- Amazon Linux 2023 (x86_64) as the base AMI. Other Linux versions can work, but
  the scripts assume Amazon Linux 2023 package names, systemd paths and disk
  device names.
- An app that keeps all its state under one directory.

## Getting started

```bash
cp config.env.example config.env
$EDITOR config.env                 # set region, AZ, subnet, security group, account id
```

Then work through [`docs/02-setup-guide.md`](docs/02-setup-guide.md) in order.
Every step that deletes or overwrites something comes after a step that checks
it is safe. The only downtime is one planned cutover at the end.

## Things to know before you start

1. **Your data can't stay on the boot disk.** A launch template always creates a
   fresh boot disk from the AMI. You can't hand an old boot disk to a new
   instance. If your state lives on the boot disk today, step 3 of the setup
   guide moves it to its own volume.
2. **Mount the volume at the app user's home directory.** Virtualenvs, scripts
   and installed tools store full paths to files in the home directory. If the
   volume mounts at the same path, all of those paths keep working.
3. **Create the data volume fresh. Don't make it from a snapshot.** A volume
   made from an AMI snapshot has the same filesystem ID (UUID) as the boot disk
   of every instance built from that AMI. With two disks sharing one UUID, XFS
   refuses to mount the second one. After a reboot, Linux can also boot from the
   wrong disk. A new, freshly formatted volume gets its own UUID, so neither
   problem can happen.
4. **Attach and mount the volume from a systemd unit, not user-data.** User-data
   runs only on an instance's first boot. After a reboot the volume would stay
   unmounted and the gateway would not start.
