# ring — RX/TX Ring Buffers

## What it controls

The number of descriptors in the NIC's receive and transmit ring buffers. Larger rings absorb traffic bursts without dropping frames; smaller rings reduce memory usage and latency.

## TuneD syntax

```ini
[net]
ring=rx 4096 tx 4096
```

Equivalent to `ethtool -G <iface> rx 4096 tx 4096`.

Check current values: `ethtool -g <iface>`.

## Value range

Minimum is driver-dependent (typically 64–256). Maximum 4096 for vmxnet3, enic, and i40e. bnxt_en supports up to 8191 but 4096 is sufficient.

## Per-driver decisions

| Driver | Decision | Rationale |
|--------|----------|-----------|
| vmxnet3 | **rx 4096 tx 4096** | Fixes `ring_full` drops (commonly millions at default 1024/512) |
| enic | No change | Ring buffers managed by UCS firmware via VIC profile |
| i40e | **rx 4096 tx 4096** | Intel recommended maximum for X710/XL710 |
| bnxt_en | **rx 4096 tx 4096** | Broadcom recommended for high-throughput workloads |

## Trade-offs

**Pros of large ring buffers:**
- Absorbs bursts during softirq delays or scheduling latency
- Prevents rx_missed_errors / ring_full drops

**Cons:**
- Bufferbloat — packets sit longer in the ring, increasing tail latency
- Higher memory consumption (~32 KB per 1024 descriptors per queue)

## Rollout note

Applying ring buffer changes on vmxnet3 causes a ~1 second NIC reset. On control-plane nodes this triggers a brief API server blip. Apply sequentially across masters, not in parallel.

## References

- [KCS 5637801](https://access.redhat.com/solutions/5637801) — Adjusting ring buffers on RHEL
- [KCS 5185811](https://access.redhat.com/solutions/5185811) — Ring buffer sizing guidance
- [KCS 2810371](https://access.redhat.com/solutions/2810371) — NIC drops troubleshooting
- [VMware KB 437897](https://knowledge.broadcom.com/external/article?legacyId=437897) — vmxnet3 ring sizing
- Intel X710/XL710 Tuning Guide (doc 334019)
