# net.core.netdev_budget / netdev_budget_usecs

## What it controls

How much work the kernel's NAPI polling loop does per softirq cycle. Two parameters work together:
- **netdev_budget** — max packets processed per poll cycle
- **netdev_budget_usecs** — max time (microseconds) spent per poll cycle

Whichever limit is hit first ends the cycle. This prevents a busy NIC from monopolizing the CPU.

## TuneD syntax

```ini
[sysctl]
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 4000
```

Check current values:
```bash
sysctl net.core.netdev_budget net.core.netdev_budget_usecs
```

## Defaults

| Parameter | Kernel default |
|-----------|---------------|
| netdev_budget | 300 |
| netdev_budget_usecs | 2000 |

## Per-role decisions

| Environment | netdev_budget | netdev_budget_usecs | Rationale |
|-------------|--------------|---------------------|-----------|
| VMs (vmxnet3, enic) | 300 (default) | 2000 (default) | Virtual NICs have lower line rates; defaults are sufficient |
| BM (i40e, bnxt_en) | **600** | **4000** | 10GbE line rates exceed what 300/2000 can drain per cycle |

## Why budget_usecs matters

At 10GbE, packets arrive fast enough that the default 2000 µs time limit causes NAPI to exit before processing all 600 budgeted packets. Raising `budget_usecs` to 4000 µs gives the poll loop enough time to actually drain the budget.

Setting `netdev_budget=600` without also raising `budget_usecs` is ineffective — the time limit, not the packet limit, is the binding constraint at high packet rates.

## Diagnostics

Watch for `time_squeeze` in `/proc/net/softnet_stat` (column 3). Non-zero and growing values indicate NAPI is being forced to exit before draining all pending packets.

```bash
awk '{print $3}' /proc/net/softnet_stat | paste -sd+ | bc
```

## References

- [KCS 1241943](https://access.redhat.com/solutions/1241943) — NAPI budget tuning for high-throughput NICs
