# transparent_hugepages

## What it controls

Transparent Huge Pages (THP) allow the kernel to automatically promote 4 KB pages to 2 MB huge pages without application changes. This reduces TLB misses for large memory workloads but introduces compaction latency when the kernel defragments memory to create contiguous 2 MB regions.

## TuneD syntax

```ini
[vm]
transparent_hugepages=never
```

Check current value:
```bash
cat /sys/kernel/mm/transparent_hugepage/enabled
```

Output shows available options with the active one in brackets:
```
always [madvise] never
```

## Per-role decisions

| Role | Value | Rationale |
|------|-------|-----------|
| Control plane | **always** (keep) | RH confirmed: API server and etcd benefit from reduced TLB misses; benefits outweigh etcd compaction risk |
| Infra | **always** (keep) | HAProxy and router pods benefit from huge pages for connection buffers |
| Workers | **never** | Compaction latency causes unpredictable stalls for application workloads |

## Why workers = never

THP compaction runs asynchronously (via `khugepaged`) and synchronously (on page faults). On worker nodes running latency-sensitive application pods:
- Synchronous compaction can stall a process for milliseconds
- `khugepaged` competes for CPU and causes jitter
- Applications that allocate/free memory frequently trigger compaction storms

Setting `never` disables THP entirely, eliminating compaction overhead. Applications that benefit from huge pages can still use explicit `madvise(MADV_HUGEPAGE)`.

## Why control plane = always (kept)

Red Hat confirmed (Case 04495863 Q5) that for control-plane nodes:
- etcd benefits from huge pages for its memory-mapped database
- API server's large heap benefits from reduced TLB pressure
- The compaction risk is acceptable because CP workloads have more predictable memory patterns

## Condition to revisit

If etcd `fsync` 99th percentile exceeds 10 ms and compaction stalls are identified as the cause (via `perf` or `trace-cmd`), reconsider setting CP nodes to `madvise` instead of `always`.

Check etcd fsync latency:
```bash
etcdctl endpoint status --write-out=table
# Or from Prometheus: histogram_quantile(0.99, etcd_disk_wal_fsync_duration_seconds_bucket)
```

## References

- [KCS 6973278](https://access.redhat.com/solutions/6973278) — THP guidance for OpenShift
- Case 04495863 Q5 — THP decision for control plane vs workers
