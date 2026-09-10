# Self-healing spot instance for an always-on gateway

Runs a stateful, always-on service (here: the KiroCrew Discord/Slack gateway) on
an EC2 **spot** instance that AWS can reclaim at any time, and gets it back
automatically — same data, no manual steps — for roughly a third of the
on-demand price.

## What it does

- AWS reclaims the spot instance → an Auto Scaling group launches a replacement
- The replacement **re-attaches the same EBS data volume** and mounts it at the
  application user's home directory
- systemd starts the gateway; a `tmux` session is recreated for log watching
- Total gap: **2-4 minutes**, unattended
- A 2-minute interruption notice triggers a clean drain (stop, sync, unmount,
  detach) so the next instance does not have to force-detach or replay a journal
- If storage cannot be attached, the instance marks itself Unhealthy so the ASG
  replaces it — instead of sitting there "healthy" with a dead application

## What it does not do

- **Zero downtime.** A single EBS volume attaches to one instance at a time, so
  there is always a gap. See `docs/01-architecture.md`.
- **Survive an AZ-wide capacity shortage.** The volume pins you to one
  Availability Zone. If every configured instance type is unavailable there, you
  are down until capacity returns (the ASG keeps retrying on its own).
- **Suit every workload.** AWS explicitly does not recommend spot for stateful,
  fault-intolerant workloads. This design manages that risk; it does not remove
  it. Read `docs/05-cost-and-tradeoffs.md` before adopting it.

## Documentation

| Document | Read it when |
|---|---|
| [`docs/01-architecture.md`](docs/01-architecture.md) | You want to understand *why* it is built this way, and the constraints that forced each decision |
| [`docs/02-setup-guide.md`](docs/02-setup-guide.md) | You are deploying it, from an existing single-instance setup or from scratch |
| [`docs/03-operations.md`](docs/03-operations.md) | It is running and you need to attach to logs, deploy code, resize, or rebuild the AMI |
| [`docs/04-troubleshooting.md`](docs/04-troubleshooting.md) | Something is broken |
| [`docs/05-cost-and-tradeoffs.md`](docs/05-cost-and-tradeoffs.md) | You are deciding whether spot is the right call, or want to reduce the bill |

## Repository layout

```
config.env.example            all deployment values in one place; copy to config.env
docs/                         the five documents above
scripts/
  build-ami.sh                runs on a throwaway builder; bakes the AMI
  migrate-home.sh             two-pass rsync of an existing home onto the volume
  instance/
    kirocrew-storage.sh       attach + mount the data volume, every boot
    kirocrew-spot-watch.sh    drain cleanly on an interruption notice
    kirocrew-selfheal.sh      mark Unhealthy so the ASG replaces a broken instance
  systemd/
    kirocrew-storage.service  ordering + OnFailure wiring
    kirocrew.service          the application, Restart=always
    kirocrew-tmux.service     attachable log session
    kirocrew-spot-watch.service
    kirocrew-selfheal.service static; only reachable via OnFailure
templates/
  iam-trust-policy.json
  iam-instance-policy.json    least-privilege, with an explicit Deny backstop
  launch-template.json
  asg.json
```

## Prerequisites

- An AWS account, and the AWS CLI v2 authenticated with permissions for EC2,
  Auto Scaling, IAM, SSM and CloudWatch
- One VPC subnet in the AZ where the data volume will live, with a route to an
  internet gateway (the application needs outbound access; nothing inbound is
  required)
- Amazon Linux 2023 x86_64 as the base AMI. Other distributions work but the
  package names, `/etc/systemd` paths and NVMe device symlinks in the scripts
  assume AL2023.
- A workload whose state lives entirely under one directory tree

## Quick start

```bash
cp config.env.example config.env
$EDITOR config.env                 # fill in region, AZ, subnet, SG, account id
```

Then follow [`docs/02-setup-guide.md`](docs/02-setup-guide.md) in order. It is
written so that every destructive step comes after a verification step, and so
that the only outage is a single planned cutover window.

## Design notes worth knowing before you start

1. **The data volume must not be a root volume.** If your state currently lives
   on the instance's boot disk, you cannot re-attach that disk to a replacement
   — a launch template always creates a fresh root volume from the AMI. Step 3
   of the setup guide migrates state onto a dedicated volume.
2. **Mount the volume at the application user's home directory.** Virtualenvs,
   shebangs and toolchain installs bake in absolute paths. Mounting at the
   original path means nothing needs rewriting.
3. **Give the data volume its own filesystem UUID.** A volume created from an
   AMI snapshot carries the *same* filesystem UUID as every instance's root
   volume from that AMI. Two disks with one UUID makes XFS refuse to mount and
   can make the initramfs pick the wrong root after a reboot. A freshly created
   and formatted volume avoids the whole class of problem.
4. **The attach/mount logic belongs in a systemd unit, not user-data.**
   User-data runs once per instance; a reboot would leave the volume unmounted
   and the application dead.
