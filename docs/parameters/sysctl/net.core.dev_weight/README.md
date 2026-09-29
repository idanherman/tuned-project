# net.core.dev_weight (NAPI per-device poll budget)

## Status: Under investigation

## What it controls

Scales the effective per-device NAPI poll budget. Each NIC driver registers a NAPI weight (typically 64 packets) — the maximum packets processed per `napi_poll()` call for one device. The `dev_weight` sysctl acts as a multiplier:

```
effective_weight = driver_napi_weight × (dev_weight / 64)
```

With the default `dev_weight = 64`, the multiplier is 1.0, so each NAPI instance processes up to 64 packets per poll.

## Relationship with netdev_budget

These two parameters work at different levels:

| Parameter | Scope | Default | Controls |
|-----------|-------|---------|----------|
| `dev_weight` | Per-device per-poll | 64 | How many packets ONE device can process in ONE `napi_poll()` call |
| `netdev_budget` | Global per-softirq | 300 | How many packets ALL devices can process in ONE `net_rx_action()` softirq |

With 8 queues, each limited to 64 packets: one softirq processes at most 8 × 64 = 512 packets before the per-device limit applies. The global `netdev_budget` of 600 is rarely the binding constraint.

## TuneD syntax

```ini
[sysctl]
net.core.dev_weight = 128
```

Check current value:
```bash
sysctl net.core.dev_weight
```

## Default

```
net.core.dev_weight = 64
```

## When to tune

- If `softnet_stat` column 3 (time_squeeze) is growing AND `netdev_budget` increase didn't help
- The per-device weight may be the real bottleneck on single-NIC nodes

## Trade-offs

- **Pro:** Allows each NIC to process more packets per poll — reduces squeezes
- **Con:** On multi-NIC nodes, a busy NIC can starve quieter NICs (e.g., primary traffic NIC could delay iSCSI processing)
- **Con:** Higher values mean longer softirq hold time per device, potentially impacting latency-sensitive workloads

## Per-node decision

| Node type | Recommendation |
|-----------|---------------|
| BM (single primary NIC) | Consider `128` if squeezes persist after netdev_budget increase |
| BM (multi-NIC: primary + iSCSI) | Caution — raising may starve iSCSI NIC processing |
| VMs | Default (64) — leave low to avoid hypervisor scheduling penalties |

## References

- Kernel documentation: `Documentation/networking/ip-sysctl.rst`
- [KCS 1241943](https://access.redhat.com/solutions/1241943) — netdev_budget tuning (includes dev_weight context)
- See also: `docs/packet-path/README.md` for the NAPI weight explanation in the packet processing path
