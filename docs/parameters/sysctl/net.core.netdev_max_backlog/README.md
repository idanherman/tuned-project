# net.core.netdev_max_backlog

## What it controls

The maximum number of packets queued on the per-CPU input (backlog) queue before the kernel starts dropping. When packets arrive faster than softirq can process them, they queue here.

## TuneD syntax

```ini
[sysctl]
net.core.netdev_max_backlog = 5000
```

Check current value:
```bash
sysctl net.core.netdev_max_backlog
```

## Default

1000

## Per-role decisions

| Environment | Value | Rationale |
|-------------|-------|-----------|
| VMs (vmxnet3) | 1000 (default) | Typically no `softnet_drops` on VMs; backlog not a bottleneck |
| BM (i40e, bnxt_en, enic) | **5000** | Fixes millions of `softnet_drops` seen at default 1000 |

## Tuning methodology

From [KCS 1241943](https://access.redhat.com/solutions/1241943):

> Double the value until column 2 of `/proc/net/softnet_stat` stops growing, up to 10000.

Starting from 1000 → 2000 → 5000 is a reasonable progression. Values above 10000 rarely help and increase memory usage.

## Diagnostics

Column 2 of `/proc/net/softnet_stat` shows per-CPU backlog overflow drops:

```bash
# Total softnet_drops across all CPUs
awk '{total += strtonum("0x"$2)} END {print total}' /proc/net/softnet_stat
```

Re-run diagnostics after deployment to verify drops have stopped.

## References

- [KCS 1241943](https://access.redhat.com/solutions/1241943) — Backlog tuning guidance
- Case 04495863 Q2 — softnet_drops on bare-metal workers
