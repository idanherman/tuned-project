# net.ipv4.tcp_max_syn_backlog

## What it controls

The maximum number of pending (half-open) TCP connections — SYNs received but not yet fully established (ACK not received). Protects against SYN floods and handles bursts of incoming connection requests.

## TuneD syntax

```ini
[sysctl]
net.ipv4.tcp_max_syn_backlog = 8192
```

Check current value:
```bash
sysctl net.ipv4.tcp_max_syn_backlog
```

## Default

1024

## Per-role decisions

| Role | Value | Rationale |
|------|-------|-----------|
| Infra nodes | **8192** | High connection rate from router pods handling external traffic |
| All others | 1024 (default) | Worker nodes receive connections via pod networking, not directly |

## Why infra only

Infra nodes run the OpenShift router (HAProxy), which is the first point of contact for all external traffic. During traffic spikes or slow backends, the SYN backlog can fill up if the default is too small. Worker nodes receive traffic through the cluster network after the router has already accepted the connection.

## Diagnostics

Check for SYN backlog overflows:
```bash
netstat -s | grep "SYNs to LISTEN"
# or
nstat -z TcpExtListenOverflows TcpExtListenDrops
```

Non-zero `ListenOverflows` or `ListenDrops` indicate the SYN backlog is too small.

## References

- RH-PS-Router-Optimization-Template (Red Hat PS, 2025)
