# net.ipv4.tcp_no_metrics_cache

## Status: Recommended (supplementary to tcp_rmem fix)

## What it controls

When disabled (`= 1`), prevents the kernel from caching TCP connection metrics (RTT, congestion window, ssthresh) per destination IP. By default (`= 0`), the kernel stores learned metrics from closed connections and applies them to NEW connections to the same destination.

## TuneD syntax

```ini
[sysctl]
net.ipv4.tcp_no_metrics_cache = 1
```

Check current value:
```bash
sysctl net.ipv4.tcp_no_metrics_cache
```

## Default

```
net.ipv4.tcp_no_metrics_cache = 0   (caching enabled)
```

## Why it matters

When TCP connects to a host, the kernel caches learned metrics (congestion window, ssthresh, RTT) keyed by destination IP. On the next connection to the same IP, those cached values are used as starting points instead of the defaults.

**Problem with the enic regression (RHEL-97545):** If a connection was established BEFORE the tcp_rmem fix was deployed, the "learned" window size is the broken small value. Even after deploying the fix, stale cached metrics from before the fix can be served to new connections to the same destination, preventing them from using the corrected initial buffer size.

Setting `tcp_no_metrics_cache = 1` forces every new connection to start fresh from the tcp_rmem initial value rather than potentially using stale/broken cached values.

## When to use

- As a supplementary measure alongside the tcp_rmem=3MB fix for enic nodes
- After changing tcp_rmem values, to ensure new connections use the updated values immediately
- Not a standalone fix — it only prevents cached metrics from overriding the new tcp_rmem initial

## Trade-offs

- **Pro:** Eliminates stale metric poisoning after tcp_rmem changes
- **Con:** Every new connection starts from scratch (no benefit from previously-learned RTT/cwnd). This can make the first few packets of each connection slightly slower as TCP re-learns the optimal window size.
- On high-connection-rate nodes, disabling the cache means more slow-start phases

## Per-node decision

| Node type | Recommendation |
|-----------|---------------|
| BM (enic) | Set to `1` if deploying the tcp_rmem=3MB fix |
| BM (i40e, bnxt_en) | Not needed (no tcp_rmem change) |
| VMs (vmxnet3) | Not needed (no tcp_rmem change) |

## References

- Kernel documentation: `Documentation/networking/ip-sysctl.rst`
- Case 04495863 — tcp_rmem fix context
