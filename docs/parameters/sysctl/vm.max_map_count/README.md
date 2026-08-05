# vm.max_map_count

## What it controls

The maximum number of memory-mapped regions (VMAs — Virtual Memory Areas) a single process can have. Each `mmap()` call, shared library load, or memory-mapped file consumes a VMA slot.

## TuneD syntax

```ini
[sysctl]
vm.max_map_count = 262144
```

Check current value:
```bash
sysctl vm.max_map_count
```

## Default

65530

## Per-role decisions

| Role | Value | Rationale |
|------|-------|-----------|
| Infra nodes | **262144** | Connection-heavy HAProxy and related services need more VMAs |
| All others | 65530 (default) | Sufficient for typical pod workloads |

## Why raise it

HAProxy and other connection-heavy services on infra nodes create many memory mappings for:
- Thread stacks
- Shared library mappings
- Per-connection buffer allocations (depending on allocator)

When `max_map_count` is exhausted, `mmap()` fails with `ENOMEM`, which can crash processes or prevent new connections.

The value 262144 (4× default) is a commonly recommended setting for infrastructure services and is also required by Elasticsearch if it runs on the same nodes.

## Diagnostics

Check current VMA count for a process:
```bash
# For a specific PID
wc -l /proc/<pid>/maps

# Find the process with the most VMAs
find /proc -maxdepth 2 -name maps 2>/dev/null | \
  xargs wc -l 2>/dev/null | sort -n | tail -5
```

## References

- RH-PS-Router-Optimization-Template (Red Hat PS, 2025)
