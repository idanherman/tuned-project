# net.ipv4.tcp_keepalive_time / tcp_keepalive_intvl / tcp_keepalive_probes

## Status: Medium priority (proactive hardening)

## What it controls

TCP keepalive parameters control how the kernel detects dead peers on idle connections:

| Parameter | Meaning | Default |
|-----------|---------|---------|
| `tcp_keepalive_time` | Seconds of idle before sending first keepalive probe | 7200 (2 hours) |
| `tcp_keepalive_intvl` | Seconds between subsequent probes after the first | 75 |
| `tcp_keepalive_probes` | Number of failed probes before declaring connection dead | 9 |

With defaults: a dead peer is detected after 7200 + (75 × 9) = **7875 seconds (~2.2 hours)**.

## TuneD syntax

```ini
[sysctl]
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
```

With these values: dead peer detected after 600 + (30 × 5) = **750 seconds (~12.5 minutes)**.

Check current values:
```bash
sysctl net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes
```

## Why it matters

In air-gapped environments with long-lived connections:

- **iSCSI connections** to NetApp via Trident: if a storage controller fails over, the initiator holds the dead connection for 2+ hours before detecting it
- **etcd** connections between control-plane nodes: a network partition holds connections open for 2 hours (etcd has its own heartbeat, but the TCP layer doesn't know the peer is gone)
- **OVN-K** geneve tunnel endpoints: dead tunnel connections waste connection tracking entries

Shorter keepalive times mean faster detection of dead peers, faster failover, and fewer stale connections consuming resources.

## Per-node decision

| Node type | Recommendation |
|-----------|---------------|
| BM workers (iSCSI) | Lower keepalive_time to 600s — faster storage failover detection |
| Control plane | Consider 600s — faster etcd peer detection (but etcd has its own heartbeat at 500ms) |
| Infra/router | Consider 600s — faster backend health detection |

## Trade-offs

- **Pro:** Faster dead peer detection, fewer stale connections
- **Con:** More keepalive traffic on the network (negligible — one small packet per connection every 600s)
- **Con:** Can prematurely kill legitimately idle connections if set too aggressively (don't go below 300s)

## Important note

These are KERNEL defaults. Many applications override them per-socket:
- etcd uses its own gRPC keepalive (10-30s)
- HAProxy has its own `timeout server` / `timeout client`
- Kubelet has its own HTTP keepalive

The kernel values only apply to connections where the application does NOT set its own keepalive. They serve as a safety net for connections that slip through without application-level keepalive.

## References

- Kernel documentation: `Documentation/networking/ip-sysctl.rst`
- NetApp Trident iSCSI best practices
