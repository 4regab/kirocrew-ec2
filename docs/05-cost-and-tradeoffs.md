# 05 — Cost and tradeoffs

## Read this before adopting

AWS's own [spot best practices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html)
state that spot is unsuitable for workloads that are inflexible, stateful or
fault-intolerant, and is not recommended where occasional unavailability of the
full target capacity cannot be tolerated. *(Paraphrased for licensing
compliance.)*

An always-on stateful gateway pinned to one AZ is all three. This design manages
that risk carefully; it does not eliminate it. If the service being unreachable
for a couple of hours is genuinely unacceptable, no spot configuration will give
you what you want — pay for on-demand and stop fighting it.

If a few minutes of downtime a handful of times a month is merely annoying, spot
saves you roughly two thirds.

## Example monthly cost

Illustrative, from a real deployment: 4 vCPU / 16 GiB in us-east-1, single AZ.

| Item | Monthly |
|---|---|
| Spot instance (m5.xlarge @ ~$0.0625/hr) | ~$42 |
| Public IPv4 address | $3.60 |
| Data volume, 40 GiB gp3 | $3.20 |
| Root volume, 8 GiB gp3, disposable | $0.64 |
| ASG, launch template, IAM, CloudWatch alarm, SNS | $0 |
| **Total** | **~$49** |

Same instance on demand is ~$121/month, or ~$85 with a one-year Compute Savings
Plan. So spot is saving roughly $40-70/month here.

Optional additions: daily DLM snapshots ~$0.05/GiB-month of changed blocks; each
retained AMI costs its root snapshot.

## Where the money actually is

**Instance size dominates.** It is ~85% of the bill. Measure before you size —
`free -m` and `uptime` under real load. Do not assume the current size is
correct in either direction; a box that looks idle on memory may be CPU-bound,
and vice versa.

**Burstable versus sustained CPU is a trap in both directions.** A `t3.xlarge`
may be cheaper per hour than an `m5.xlarge`, but t-family instances throttle to a
CPU baseline once credits are exhausted. For a workload showing a sustained load
average near or above its vCPU count, the non-burstable family is worth a few
percent more. Conversely, a genuinely bursty workload wastes money on m-family.

**Spot price differs per AZ**, sometimes by 15-20%. Your data volume pins the AZ,
so check prices *before* creating the volume — that decision locks in your rate:

```bash
aws ec2 describe-spot-price-history --region $AWS_REGION \
  --instance-types m5.xlarge --product-descriptions "Linux/UNIX" \
  --start-time $(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output table
```

**Do not set a max spot price.** Leaving it unset means you pay the market rate
and are only interrupted for capacity. Setting a cap adds price-based
interruptions for no saving.

**The public IPv4 charge is hard to avoid.** ~$3.60/month, the same whether it is
an Elastic IP or auto-assigned. Removing it means a NAT gateway (~$32/month) or
three SSM interface endpoints (~$21/month) — both worse. Unless you already have
NAT for other reasons, keep the address.

## Availability tradeoffs made here

| Decision | Gain | Cost |
|---|---|---|
| Single AZ (forced by the volume) | Simple, one volume, no replication | An AZ-wide capacity shortage takes you down |
| `MaxSize=1` (forced by single-writer EBS) | Never two instances, never a duplicate connection | 2-4 minute gap per interruption |
| Spot-only, no on-demand base | ~65% saving | No automatic fallback when capacity runs out |
| 12 instance types | Many capacity pools, much faster recovery | Performance varies by which type you land on |
| EC2-level health checks | Simple, free | A booted-but-broken app is invisible; mitigated by self-heal + alarm |

## If you need better availability

Roughly in order of cost:

1. **More instance types.** Free, and the single most effective change. Add every
   same-architecture family with adequate memory.
2. **CloudWatch alarm on `GroupInServiceInstances < 1`.** Free; turns a silent
   outage into a notification.
3. **A second AZ with EFS instead of EBS.** Removes the AZ pin entirely. But
   EFS is NFS: SQLite and similar file-locking databases are unreliable on it.
   Only viable if your state is NFS-safe.
4. **On-demand base capacity of 1.** True 24/7, and mathematically identical to
   just running on-demand for a single-instance workload.
5. **Two instances, active/standby, with replication.** Real high availability,
   double the compute, and a substantially more complex system.

## Alternative considered: persistent spot request with `stop`

Worth knowing about, because for some workloads it is simpler than everything in
this repository.

Per the [interruption behaviour docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/interruption-behavior.html),
a **persistent** spot request can set interruption behaviour to `stop`. EC2 then
stops the instance instead of terminating it, preserving the root and attached
volumes, and restarts it when capacity returns.

That means **no data volume, no attach logic, no ASG, no AMI** — the same
instance comes back with everything in place.

The same document lists why it was rejected here:

- **Only EC2 can restart an interrupted stopped instance.** No manual override.
- Restart requires the **same AZ and the same instance type**, so there is no
  diversification — the single biggest lever on recovery time.
- While stopped you may change some attributes **but not the instance type**, so
  you cannot chase capacity elsewhere.
- If the root volume is detached, a start attempt fails and EC2 terminates the
  instance.
- Cancelling the request terminates the stopped instance.

Choose it if state preservation matters far more than recovery speed and you are
comfortable being unable to intervene. Choose the ASG design in this repository
if you would rather trade a little complexity for twelve capacity pools and the
ability to act during an outage.

Spot **hibernation** is a third option, preserving RAM as well, but it
[requires an encrypted EBS root volume](https://aws.amazon.com/about-aws/whats-new/2019/05/enable-ec2-hibernation-without-specifying-encryption-intent/)
and [cannot be enabled on an existing instance](https://docs.aws.amazon.com/en_en/AWSEC2/latest/UserGuide/hibernating-prerequisites.html),
so adopting it means rebuilding from scratch.
