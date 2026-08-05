# net.netfilter.nf_conntrack_max

## Status: Future

## What it controls

The maximum number of entries in the kernel's connection tracking (conntrack) table. Every tracked network connection (TCP, UDP, ICMP) consumes one entry. When the table fills, new connections are dropped.

## TuneD syntax

```ini
[sysctl]
net.netfilter.nf_conntrack_max = 524288
```

Check current value:
```bash
sysctl net.netfilter.nf_conntrack_max
```

## Default

262144

## Why it matters for OpenShift

OVN-Kubernetes uses conntrack for all pod-to-pod and pod-to-service traffic. On dense nodes running many pods with high connection rates, the default 262144 entries can be exhausted. When this happens:
- New connections are silently dropped
- `insert_failed` counter increments in conntrack stats
- Symptoms appear as intermittent connectivity failures, not obvious errors

## Why postponed

1. Check `insert_failed` in your diagnostics — if zero, this is not urgent
2. Primary network fixes (ring, backlog, tcp_rmem) address the urgent symptoms
3. Conntrack exhaustion is a scaling concern, not a current bottleneck

## When to revisit

Check conntrack pressure after primary fixes are deployed:

```bash
# Current entries vs max
sysctl net.netfilter.nf_conntrack_count net.netfilter.nf_conntrack_max

# Check for insert failures
conntrack -S | grep insert_failed
```

If `nf_conntrack_count` exceeds 80% of `nf_conntrack_max` under load, or `insert_failed` is non-zero, raise the limit.

## Recommended value (when applied)

Double to 524288, or scale based on peak usage:
```
max = peak_conntrack_count × 1.5
```

Also increase the hash table size proportionally:
```ini
net.netfilter.nf_conntrack_buckets = 131072
```

## References

- OVN-Kubernetes networking documentation
- `man conntrack` — connection tracking administration
