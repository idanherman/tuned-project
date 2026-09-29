# net.ipv4.tcp_rmem / tcp_wmem

## Status: CRITICAL

## What it controls

TCP auto-tuning parameters for per-socket receive (and send) buffer sizes. Three space-separated values:

| Position | Meaning |
|----------|---------|
| min | Minimum buffer size, even under memory pressure |
| initial | Default buffer size at connection start; auto-tuning grows from here |
| max | Maximum buffer size auto-tuning can reach (capped by `rmem_max`) |

## TuneD syntax

```ini
[sysctl]
net.ipv4.tcp_rmem = 4096 3145728 6291456
net.ipv4.tcp_wmem = 4096 3145728 6291456
```

Check current values:
```bash
sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem
```

## Defaults

```
net.ipv4.tcp_rmem = 4096 131072 6291456   (4K / 128K / 6M)
```

## The enic regression (RHEL-97545)

**This is typically the single most impactful fix for enic environments.** On RHEL 9.4 kernels (5.14.0-427.x), a kernel bug breaks TCP receive window auto-tuning on Cisco enic NICs:

- The receive window gets stuck at the **initial** value (default 128 KB)
- Auto-tuning never grows the window beyond initial
- Result: throughput capped at ~1–5 MB/s instead of expected 1+ GB/s

The fix is to set the **initial** value high enough that the stuck window still provides adequate throughput. Setting initial to 3 MB (3145728) provides a ~3 GB/s effective window at typical RTTs.

Tracked as RHEL-97545, documented in [KCS 7127975](https://access.redhat.com/solutions/7127975).

## Per-driver decisions

| Driver | tcp_rmem | Rationale |
|--------|----------|-----------|
| vmxnet3 | Default | Not affected by RHEL-97545 |
| enic | **4096 3145728 6291456** | Workaround for stuck auto-tuning |
| i40e | `4096 131072 16777216` | Not affected by RHEL-97545; max raised to 16MB to match rmem_max for iSCSI |
| bnxt_en | `4096 131072 16777216` | Same as i40e — max raised for iSCSI, initial left at default |

## tcp_wmem values

The **send-side** (`tcp_wmem`) is NOT affected by the enic regression — auto-tuning works correctly for TX. Values differ by intent:

| Driver | tcp_wmem | Rationale |
|--------|----------|-----------|
| enic | `4096 87380 16777216` | Initial=87KB (standard), max=16MB (for iSCSI large block writes) |
| i40e | `4096 131072 16777216` | Initial=128KB (RHEL default), max=16MB (iSCSI) |
| bnxt_en | `4096 131072 16777216` | Same as i40e |
| vmxnet3 | Default (`4096 16384 4194304`) | No iSCSI on VMs |

**Why enic tcp_wmem initial is 87380 (not 3MB):** The tcp_rmem fix raises the initial to 3MB because the RECEIVE window is broken. The SEND side works normally — 87KB initial is sufficient and auto-tuning grows it as needed. Raising tcp_wmem initial to 3MB would waste memory without fixing any bug.

## Trade-offs of high initial value

- Each new TCP socket immediately allocates ~3 MB of receive buffer
- On connection-heavy nodes this increases memory pressure
- Only applied to enic nodes where the regression is confirmed

## Diagnostics

See [diagnosing-enic-regression.md](diagnosing-enic-regression.md) for step-by-step detection of RHEL-97545.

## References

- [KCS 7127975](https://access.redhat.com/solutions/7127975) — enic TCP auto-tuning regression
- RHEL-97545 — upstream bug tracker
- Case 04495863 — original discovery and RH confirmation
