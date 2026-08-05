# C-States (CPU Idle States)

## Status: Under investigation

## What it controls

CPU C-states are progressively deeper idle states that reduce power consumption when a core has no work:

| State | Name | Wake-up latency |
|-------|------|----------------|
| C0 | Active | 0 (running) |
| C1 | Halt | ~1 µs |
| C1E | Enhanced Halt | ~10 µs |
| C3 | Sleep | ~50 µs |
| C6 | Deep Sleep | ~100+ µs |

Deeper states save more power but take longer to wake up when an interrupt arrives.

## Boot parameter

```
intel_idle.max_cstate=1
```

**This cannot be set via TuneD `[sysctl]`.** It requires either:
- **MachineConfig** — kernel boot arguments
- **PerformanceProfile** — which sets reserved/isolated CPUs and can restrict C-states

## Why it matters

When a CPU core is in a deep C-state (C3/C6) and a NIC interrupt arrives, the core takes 50–100+ µs to wake up. During this time:
- Ring buffer fills with incoming packets
- `rx_no_bufs` / `rx_missed_errors` increment
- Packets may be dropped before the core is ready to process them

This is particularly problematic on bare-metal nodes with high-speed NICs (10GbE+) where packet inter-arrival times are measured in microseconds.

## Current state

The `openshift-node-performance-profile` inherits from `throughput-performance`, which sets `governor=performance` (max CPU frequency). However, this may **not** fully restrict C-states — the governor controls frequency scaling, not idle states.

To verify current C-state behavior:
```bash
# Check available C-states
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name

# Check if deeper states are being used
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/usage
```

## Plan

1. Deploy network fixes first (ring buffers, backlog, NAPI budget)
2. Re-run diagnostics and check if `rx_no_bufs` continues
3. If drops persist, restrict C-states via PerformanceProfile or MachineConfig
4. Measure power/thermal impact of disabling deep C-states

## Trade-offs

**Restricting to C1:**
- Eliminates wake-up latency for interrupt handling
- Increases power consumption and heat output
- Cores never fully idle — always drawing near-active power

**Keeping deep C-states:**
- Lower power consumption and thermals
- Risk of ring buffer overflow during wake-up from deep sleep
- Acceptable if packet rates are low enough that the ring absorbs the burst

## References

- Intel processor C-state documentation
- PerformanceProfile API — `performance.openshift.io/v2`
- `man cpupower-idle-info` — C-state inspection tools
