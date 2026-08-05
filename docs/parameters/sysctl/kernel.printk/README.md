# kernel.printk

## What it controls

Console log level for kernel messages. Four space-separated values:

| Position | Meaning |
|----------|---------|
| 1st | Console log level — messages at this priority or higher are printed to console |
| 2nd | Default message level — priority assigned to messages without an explicit level |
| 3rd | Minimum console level — lowest (most verbose) the console level can be set to |
| 4th | Default console level — used at boot before this sysctl is applied |

Lower numbers = higher priority (0=emergency, 7=debug).

## TuneD syntax

```ini
[sysctl]
kernel.printk = 4 4 1 7
```

Check current value:
```bash
sysctl kernel.printk
```

## Default

```
7   4   1   7
```

(Console shows everything up to debug level.)

## Decision

| Role | Value | Rationale |
|------|-------|-----------|
| All nodes | **4 4 1 7** | Suppress info/debug messages from console output |

## Priority: Low

This is a housekeeping change. Setting the console log level to 4 (warning) suppresses informational and debug kernel messages from the console. This reduces console noise on all nodes without affecting `dmesg` or `journalctl` output — those continue to capture all messages regardless of the console level.

## What changes

- Console level drops from 7 (debug) to 4 (warning)
- Only warnings, errors, criticals, alerts, and emergencies appear on the console
- `dmesg` and journal logs are **not affected** — all messages are still recorded

## References

- `man 2 syslog` — kernel log level documentation
