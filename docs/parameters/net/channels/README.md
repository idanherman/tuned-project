# channels — NIC Queues

## What it controls

The number of hardware TX/RX queues (channels) on the NIC. More queues enable parallel packet processing across multiple CPUs, improving throughput on multi-core systems.

## TuneD syntax

```ini
[net]
channels=combined 16
```

Equivalent to `ethtool -L <iface> combined 16`.

Check current values: `ethtool -l <iface>`.

## Per-driver decisions

| Driver | Decision | Rationale |
|--------|----------|-----------|
| vmxnet3 | 8 (auto, no change) | VMware default matches typical vCPU count |
| enic | 8 (no change) | Managed by UCS VIC profile |
| i40e | **combined 16** | TODO: verify NUMA alignment before deploying |
| bnxt_en | **combined 16** | TODO: verify NUMA alignment before deploying |

## NUMA considerations

Setting channels higher than the number of cores on a single NUMA node causes cross-NUMA interrupt delivery. This adds latency and can negate the throughput benefit of extra queues.

Verify before deploying:
```bash
# cores per NUMA node
lscpu | grep "NUMA node0"
# current channel count
ethtool -l <iface>
```

If the NIC is attached to a NUMA node with 16 cores, `combined 16` is safe. If only 8 cores, cap at `combined 8`.

## Trade-offs

**Pros of more queues:**
- Better parallelism — each queue maps to a separate CPU for softirq processing
- Reduces lock contention on single-queue bottlenecks
- Enables RSS (Receive Side Scaling) across more cores

**Cons:**
- Cross-NUMA penalty if queue count exceeds cores per NUMA node
- Diminishing returns past the point where CPU is no longer the bottleneck
- More interrupt vectors consumed

## References

- Intel X710/XL710 Tuning Guide (doc 334019)
- Cisco VIC Tuning Guide — UCS channel configuration
- Broadcom NIC Tune — bnxt_en queue recommendations
