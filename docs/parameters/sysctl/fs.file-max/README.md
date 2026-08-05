# fs.file-max / fs.nr_open

## What it controls

System-wide limits on file descriptors:

- **fs.file-max** — maximum number of file descriptors the kernel will allocate across all processes
- **fs.nr_open** — maximum number of file descriptors a single process can open (hard ceiling for `ulimit -n`)

## TuneD syntax

```ini
[sysctl]
fs.file-max = 2097152
fs.nr_open = 2097152
```

Check current values:
```bash
sysctl fs.file-max fs.nr_open
```

## Defaults

| Parameter | Default |
|-----------|---------|
| fs.file-max | ~1M (varies with RAM) |
| fs.nr_open | 1048576 |

## Per-role decisions

| Role | Value | Rationale |
|------|-------|-----------|
| Infra nodes | **2097152** (2M) | HAProxy needs 1 FD per connection (frontend + backend) |
| All others | Default | Worker nodes don't concentrate FD usage at the system level |

## Why infra needs more

HAProxy uses one file descriptor per active connection. With `maxconn=50000`, a single HAProxy process needs at least 100K FDs (50K frontend + 50K backend sockets, plus overhead). Multiple router replicas on the same infra node multiply this.

Setting both `file-max` and `nr_open` to 2M provides headroom for:
- Multiple HAProxy replicas
- Connection spikes beyond steady-state maxconn
- Other system services sharing the node

## Diagnostics

Check current FD usage:
```bash
# System-wide allocated FDs
cat /proc/sys/fs/file-nr
# Format: allocated  free  maximum
```

## References

- RH-PS-Router-Optimization-Template (Red Hat PS, 2025)
