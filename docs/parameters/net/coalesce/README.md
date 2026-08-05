# coalesce — Interrupt Coalescing

## What it controls

How long the NIC waits (or how many packets it accumulates) before raising a hardware interrupt. Coalescing reduces interrupt overhead at the cost of added latency per packet.

## TuneD syntax

```ini
[net]
coalesce=adaptive-rx on adaptive-tx on
```

Or with fixed timers:

```ini
[net]
coalesce=adaptive-rx off rx-usecs 125
```

Equivalent to `ethtool -C <iface> adaptive-rx on adaptive-tx on`.

Check current values: `ethtool -c <iface>`.

## Per-driver decisions

| Driver | Decision | Rationale |
|--------|----------|-----------|
| vmxnet3 | Default (no change) | Coalescing managed by VMware hypervisor |
| enic | 125 µs fixed | UCS VIC profile controls coalescing; matches firmware defaults |
| i40e | **rx-usecs 125, adaptive off** | Intel recommends disabling adaptive coalescing for consistent latency |
| bnxt_en | **adaptive-rx on, adaptive-tx on** | Broadcom recommends adaptive mode for mixed workloads |

## How adaptive coalescing works

With adaptive mode enabled, the NIC dynamically adjusts the interrupt delay based on traffic patterns:
- **Low traffic** → short delay (low latency)
- **High traffic** → longer delay (fewer interrupts, higher throughput)

Fixed-timer mode (`rx-usecs N`) fires an interrupt every N microseconds regardless of load. This gives predictable latency but may generate excessive interrupts under light load or insufficient coalescing under bursts.

## Trade-offs

**Lower coalescing (fewer µs / adaptive off):**
- Lower per-packet latency
- More interrupts per second → higher CPU overhead

**Higher coalescing (more µs / adaptive on):**
- Fewer interrupts → lower CPU usage
- Higher tail latency for individual packets

## References

- Intel X710/XL710 Tuning Guide (doc 334019)
- Broadcom NIC Tune — adaptive coalescing recommendations
