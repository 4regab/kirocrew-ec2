# 01 — Architecture

## The problem

A stateful, always-on service runs on a single EC2 spot instance. AWS can
reclaim that instance with two minutes' notice. When it does, the service is
gone until a human notices and rebuilds it.

The goal: automatic replacement, with the same data, unattended, while keeping
the ~65% spot discount and without ever running two copies or paying for
duplicate storage.

## Component overview

```
                    ┌────────────────────────────────────┐
                    │  Auto Scaling group  min=max=1     │
                    │  one subnet, one AZ, spot-only     │
                    │  12 interchangeable instance types │
                    └──────────────┬─────────────────────┘
                                   │ launches from
                                   ▼
                    ┌────────────────────────────────────┐
                    │  Launch template → custom AMI      │
                    │  • OS packages + toolchain         │
                    │  • 4 enabled systemd units         │
                    │  • disposable 8 GiB root           │
                    └──────────────┬─────────────────────┘
                                   │ on every boot
                                   ▼
              ┌──────────────────────────────────────────────┐
              │ kirocrew-storage.service                     │
              │  attach ──► verify UUID ──► mount at $HOME   │
              │  ──► verify sentinel paths                   │
              └───────┬───────────────────────────┬──────────┘
                 success                       failure
                      │                           │
                      ▼                           ▼
        ┌──────────────────────────┐   ┌─────────────────────────┐
        │ kirocrew.service         │   │ kirocrew-selfheal       │
        │  Restart=always          │   │  SetInstanceHealth      │
        │ kirocrew-tmux.service    │   │  → Unhealthy            │
        │ kirocrew-spot-watch      │   │  → ASG replaces me      │
        └──────────────────────────┘   └─────────────────────────┘

   Persistent: one EBS data volume (DeleteOnTermination=false)
   Disposable: the root volume, deleted with every instance
```

## The five constraints that shaped this

### 1. An EBS volume attaches to one instance, and lives in one AZ

Non-Multi-Attach EBS is single-writer, which forces `MaxSize=1`. That in turn
means a replacement **cannot** launch before the old instance is gone, so a gap
is unavoidable. Capacity Rebalancing normally pre-launches a replacement, but
that needs `MaxSize > DesiredCapacity`, which would allow two instances to fight
over the volume — and, for a chat gateway, open two connections on one bot
token.

The volume also cannot cross AZs, so the ASG must be pinned to a single subnet.
Zero downtime would require a second AZ, a second volume and replication between
them. That is a different, much larger design.

**Consequence to accept: 2-4 minutes of downtime per interruption.**

### 2. A root volume cannot be re-attached to a replacement

A launch template always creates a *new* root volume from the AMI snapshot.
There is no way to say "boot this specific existing disk". So if application
state lives on the boot disk, it cannot be carried across a replacement.

Three ways out were considered:

| Approach | Verdict |
|---|---|
| Attach the old root volume as a *secondary* disk and bind-mount the home directory out of it | Works, but permanently carries a duplicate-UUID disk (see 3), wastes capacity holding an OS you never boot, and matches no established pattern |
| Bake everything into a custom AMI, no data volume | Rejected: anything written after the AMI was created is lost on every replacement |
| **Dedicated data volume + custom AMI for the OS** | **Chosen.** Clean separation: disposable root from the AMI, persistent state on its own volume |

### 3. Filesystem UUIDs collide when volumes share an AMI ancestor

Amazon Linux mounts root by UUID:

```
root=UUID=<root-filesystem-uuid>
```

EBS snapshots are block-level copies, so a volume created from an AMI's snapshot
carries the *identical* filesystem UUID as every other instance's root volume
from that AMI. Two disks claiming one UUID causes two problems:

- XFS refuses to mount a duplicate UUID (workaround: `-o nouuid`)
- At boot, `/dev/disk/by-uuid/<uuid>` resolves to whichever device udev
  processed last. If the wrong one wins, the kernel mounts your **data** volume
  as root and boots the wrong OS. Rare, but a genuinely confusing outage.

Creating the data volume fresh and formatting it gives it a random UUID, so the
collision cannot occur. No `-o nouuid`, no boot-time ambiguity, and no need to
rewrite a UUID on a disk holding live data.

This was verified empirically: on a replacement instance, the root is
`91121373-…` and the data volume is a different UUID entirely.

### 4. The replacement boots while the old instance may still hold the volume

Termination is not instantaneous. The boot script therefore retries, and
distinguishes carefully between holders:

- holder `terminated` or `shutting-down` → safe, force-detach
- holder `running`, `pending`, `stopping`, `stopped` → **refuse**

That refusal is the single most important safety property in the design: it is
what stops a stray or duplicate instance ripping the volume away from a live
one. It is verified during setup by booting a second instance while the first is
running and confirming the log line:

```
REFUSING to steal volume from a live instance (i-xxxx is running)
```

### 5. A booted instance is not a working instance

ASG health checks are EC2-level. An instance whose application never started
still reports `Healthy`, so the ASG does nothing and you get a silent outage.

Two mechanisms close this:

- `Requires=kirocrew-storage.service` on the application unit means the app
  **cannot** start without its data. It fails loudly rather than starting
  against an empty home directory and writing fresh, empty state.
- `OnFailure=kirocrew-selfheal.service` marks the instance Unhealthy, so the
  ASG scraps it and relaunches — very likely into a different capacity pool.

## Why systemd rather than tmux as the supervisor

The obvious approach — `tmux new-session -d 'my-app'` — does not survive
contact with reality: tmux forks and exits immediately, so systemd tracks the
tmux server rather than the application. When the app crashes inside the pane,
`Restart=always` never fires and the pane just sits there dead.

A hand-rolled `while true; do app; sleep 3; done` loop inside tmux has the same
weakness in a different place: it is tied to a login session and does not come
back after a reboot.

So: **systemd runs the application directly** (`Restart=always`,
`StartLimitIntervalSec=0` so it never gives up), and a separate one-shot unit
opens a tmux session tailing `journalctl -u kirocrew -f`. You keep
`tmux attach -t kiro`, and gain real crash-restart plus log history that
survives restarts.

`StartLimitIntervalSec=0` matters more than it looks: systemd's default of three
failures in 300 seconds leaves a service *permanently* dead until someone runs
`systemctl reset-failed`. For an always-on workload that is a trap.

## Why the data volume mounts at the home directory

Virtualenvs hard-code interpreter paths in shebangs; version managers install
toolchains under the home directory; caches and credentials sit in dotfiles.
Mounting the volume at the *original* home path means every one of those
absolute paths resolves unchanged — no rewriting, no relinking, no rebuilt
virtualenv.

The AMI's own copy of the home directory is shadowed by the mount, and is
deliberately left almost empty. If the mount ever fails, the application finds
nothing rather than stale state — and `Requires=` stops it starting at all.

## Boot sequence

1. Instance boots from the custom AMI; cloud-init does its normal work
2. `kirocrew-storage.service` (after `network-online` and `cloud-init`):
   - reads instance identity from IMDSv2
   - exits early if already mounted (idempotent, so reboots are safe)
   - retries attaching for up to 10 minutes, refusing live holders
   - waits for `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volid>` —
     never the requested `/dev/sdf`, because Nitro renames it to `/dev/nvmeXn1`
     with a non-deterministic index
   - **aborts unless the filesystem UUID matches**; never formats
   - mounts, then verifies sentinel paths or unmounts and fails
3. `kirocrew.service` starts the application (gated on step 2 succeeding, and on
   `user@<uid>.service` for per-agent `systemd-run --user` scopes, which needs
   `loginctl enable-linger`)
4. `kirocrew-tmux.service` opens the log session
5. `kirocrew-spot-watch.service` begins polling IMDS

## Interruption sequence

| When | What happens |
|---|---|
| T−2min | EC2 writes the interruption notice to IMDS; the watcher sees it within 5s |
| T−2min+15s | Stop app → `sync` → unmount → detach. Volume goes `available` with a clean XFS log |
| T−0 | Instance terminates; the disposable root is deleted with it |
| T+10s | ASG launches a replacement from the best-priced available pool |
| T+60s | Storage unit attaches, verifies, mounts |
| T+90s | Application starts; tmux session recreated |
| T+2-4min | Service restored with all state intact |

## Deliberate omissions

- **No load balancer, no Elastic IP.** The service connects outbound and listens
  only on localhost. A public IPv4 costs the same whether it is an EIP or
  auto-assigned; going private would need a NAT gateway or interface endpoints,
  both more expensive than the address.
- **No encryption on the data volume**, matching the source setup. Enabling it
  is a good idea and is noted as a follow-up in `03-operations.md`.
- **No spot-to-on-demand fallback.** An ASG has no automatic fallback; the only
  real option is a permanent on-demand base of 1, which for a single-instance
  workload just means paying on-demand.
