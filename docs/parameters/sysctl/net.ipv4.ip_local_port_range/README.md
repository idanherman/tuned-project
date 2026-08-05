# net.ipv4.ip_local_port_range

## What it controls

The range of local (ephemeral) ports available for outgoing connections. When a process connects to a remote server without binding to a specific port, the kernel assigns a port from this range.

## TuneD syntax

```ini
[sysctl]
net.ipv4.ip_local_port_range = 1024 65535
```

Check current value:
```bash
sysctl net.ipv4.ip_local_port_range
```

## Default

```
32768   60999
```

This gives ~28,000 ephemeral ports.

## Per-role decisions

| Role | Value | Rationale |
|------|-------|-----------|
| Infra nodes | **1024 65535** | ~64K ports available for HAProxy backend connections |
| All others | Default (32768–60999) | Sufficient for typical workloads |

## Why infra needs more

HAProxy running as a reverse proxy opens a new ephemeral port for each backend connection. Under high concurrency, the default range of ~28K ports can exhaust, causing `EADDRNOTAVAIL` errors and connection failures.

Widening to 1024–65535 provides ~64K ports. The lower bound of 1024 avoids well-known ports (0–1023) while maximizing the available range.

## Relationship to TIME_WAIT

Ephemeral port exhaustion is exacerbated by `TIME_WAIT` sockets. Each closed connection holds its port for ~60 seconds (2×MSL). At 1000 connections/second, 60K ports can be consumed by TIME_WAIT alone. Widening the port range is the first line of defense.

## Diagnostics

```bash
# Count ephemeral ports in TIME_WAIT
ss -tan state time-wait | awk '{print $4}' | grep -c ":[3-6][0-9]*$"

# Check for port exhaustion errors
dmesg | grep "port range"
```

## References

- RH-PS-Router-Optimization-Template (Red Hat PS, 2025)
