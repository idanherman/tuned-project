# net.core.rmem_max / wmem_max

## What it controls

The hard ceiling on per-socket receive and send buffer sizes. These are system-wide maximums — no socket can have a buffer larger than these values, regardless of application request or TCP auto-tuning.

- **rmem_max** — maximum receive buffer (bytes)
- **wmem_max** — maximum send buffer (bytes)

The third value of `tcp_rmem` / `tcp_wmem` (the auto-tuning max) cannot exceed `rmem_max` / `wmem_max`.

## TuneD syntax

```ini
[sysctl]
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
```

Check current values:
```bash
sysctl net.core.rmem_max net.core.wmem_max
```

## Defaults

| Environment | Default rmem_max |
|-------------|-----------------|
| RHEL default | 212992 (208 KB) |
| BM nodes (current) | 16777216 (16 MB) |

## Per-role decisions

| Environment | Value | Rationale |
|-------------|-------|-----------|
| VMs (vmxnet3, enic) | 212992 (default) | Virtual workloads don't need large socket buffers |
| BM (i40e, bnxt_en) | **16777216** (no change) | Already set for iSCSI storage traffic; retaining |

## Relationship to tcp_rmem

`tcp_rmem` defines what TCP auto-tuning *targets*; `rmem_max` defines what it's *allowed* to reach:

```
tcp_rmem max ≤ rmem_max    (enforced by kernel)
```

If `tcp_rmem` third value is set to 6291456 (6 MB) and `rmem_max` is the default 212992, auto-tuning will be capped at 208 KB regardless of the tcp_rmem setting.

On bare-metal nodes with iSCSI, `rmem_max` should be 16 MB so that `tcp_rmem` settings are not constrained.

## References

- `man 7 socket` — SO_RCVBUF / SO_SNDBUF documentation
- `man 7 tcp` — tcp_rmem / tcp_wmem interaction with rmem_max
