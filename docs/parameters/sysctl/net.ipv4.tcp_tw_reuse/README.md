# net.ipv4.tcp_tw_reuse

## Status: Recommended for infra/router nodes

## What it controls

Allows the kernel to reuse TIME_WAIT sockets for new outbound connections when it's safe to do so (matching 5-tuple timestamps). Without it, each closed connection holds its ephemeral port in TIME_WAIT for 60 seconds, potentially causing port exhaustion under high connection rates.

## TuneD syntax

```ini
[sysctl]
net.ipv4.tcp_tw_reuse = 1
```

Values:
- `0` — disabled (default)
- `1` — enable globally
- `2` — enable for loopback only (safer, kernel 4.12+)

Check current value:
```bash
sysctl net.ipv4.tcp_tw_reuse
```

## Default

```
net.ipv4.tcp_tw_reuse = 0   (disabled)
```

## Why it matters

Each closed TCP connection enters TIME_WAIT state for 60 seconds (2x MSL). During this time, its source port is reserved and cannot be reused. At high connection rates:

- 1000 connections/sec × 60 seconds = 60,000 ports in TIME_WAIT
- Default `ip_local_port_range` is `32768-60999` = ~28,000 ports
- Result: port exhaustion, new connections fail with EADDRNOTAVAIL

Even with widened `ip_local_port_range = 1024-65535` (~64,000 ports), sustained high connection rates can exhaust the pool. `tcp_tw_reuse` allows recycling TIME_WAIT ports earlier when TCP timestamps confirm it's safe.

## When to use

| Node type | Recommendation | Why |
|-----------|---------------|-----|
| Infra/router | `1` (enable) | HAProxy creates thousands of outbound connections to backends |
| BM workers | Consider `1` | High pod-to-service connection rates |
| Control plane | `0` (default) | Low outbound connection rates |

## Trade-offs

- **Pro:** Prevents ephemeral port exhaustion; works alongside `ip_local_port_range`
- **Con:** Can break through stateful firewalls/NAT that track connections by 5-tuple (the firewall sees a "new" connection on a recently-used tuple and may drop it as invalid)
- **Con:** Only applies to outbound connections (client-side), not inbound

**In air-gapped OVN-K environments:** Generally safe — no NAT between pods, OVN-K handles pod networking directly. Stateful firewalls between nodes are uncommon.

## References

- Kernel documentation: `Documentation/networking/ip-sysctl.rst`
- RH-PS-Router-Optimization-Template (Red Hat PS, 2025)
