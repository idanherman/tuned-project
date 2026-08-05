# net.ipv4.tcp_slow_start_after_idle

## Status: Future

## What it controls

Whether TCP resets the congestion window to its initial value after a connection has been idle. When enabled (default), an idle connection must go through slow start again, gradually ramping up throughput.

## TuneD syntax

```ini
[sysctl]
net.ipv4.tcp_slow_start_after_idle = 0
```

Check current value:
```bash
sysctl net.ipv4.tcp_slow_start_after_idle
```

## Default

1 (enabled — reset congestion window after idle)

## What setting to 0 does

Disabling slow start after idle preserves the learned congestion window across idle periods. When the connection resumes sending, it immediately uses the full window instead of ramping up from scratch.

## Benefits

- **Persistent HTTP connections** resume at full throughput without a ramp-up period
- Reduces latency for bursty workloads with idle gaps between bursts
- Particularly beneficial for keep-alive connections between services

## Risks

- If network conditions changed during idle, the stale congestion window may cause packet loss
- RFC 2861 recommends decaying the window during idle periods (which this setting overrides)
- Minimal risk in datacenter environments where path capacity rarely changes

## Why postponed

This is an **optimization, not a fix**. It improves performance for idle persistent connections but does not address any current symptom (no evidence of slow-start-related latency in diagnostics).

Priority is lower than the ring buffer, backlog, and tcp_rmem changes that fix active packet loss.

## When to revisit

After primary fixes are deployed, if service-to-service latency shows periodic spikes correlated with idle connection resumption, disabling slow start after idle is the likely next step.

## References

- RFC 2861 — TCP Congestion Window Validation
- `man 7 tcp` — tcp_slow_start_after_idle documentation
