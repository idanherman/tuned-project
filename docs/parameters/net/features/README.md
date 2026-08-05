# features — NIC Offloads (ntuple / aRFS / GRO)

## What it controls

Hardware offload features on the NIC, primarily:
- **ntuple filtering** (aRFS — accelerated Receive Flow Steering): steers flows to the CPU that owns the socket, reducing cache misses
- **rx-gro-hw** (hardware Generic Receive Offload): coalesces packets in hardware before they reach the kernel

## TuneD syntax

```ini
[net]
features=ntuple on rx-gro-hw on
```

Equivalent to `ethtool -K <iface> ntuple on rx-gro-hw on`.

Check current values: `ethtool -k <iface>`.

## Per-driver decisions

| Driver | Decision | Rationale |
|--------|----------|-----------|
| vmxnet3 | No change | ntuple not supported by vmxnet3 |
| enic | **DO NOT ENABLE ntuple** | RH confirmed: pod churn makes aRFS worse on enic — stale flow entries cause missteering. See BZ 2216206 |
| i40e | **ntuple on** | Intel Flow Director; stable flow tables on bare-metal |
| bnxt_en | **ntuple on, rx-gro-hw on** | Broadcom supports both; hardware GRO reduces CPU overhead |

## Why NOT on enic

Red Hat confirmed in Case 04495863 Q4 and Case 03557602 that enabling ntuple (aRFS) on Cisco enic NICs in OpenShift environments causes performance degradation:

1. Pod churn constantly creates/destroys flows
2. aRFS flow table fills with stale entries
3. Packets get steered to wrong CPUs
4. Net result is *worse* performance than without aRFS

This is documented in BZ 2216206. Do not enable ntuple on enic under any circumstances.

## Trade-offs

**ntuple on (where supported):**
- Flows land on the CPU owning the socket → fewer cache misses
- Significant throughput improvement for long-lived connections
- Ineffective or harmful with high pod/connection churn

**rx-gro-hw on:**
- NIC coalesces small packets into larger ones before DMA
- Reduces per-packet CPU overhead
- Only beneficial if the NIC firmware supports it (check `ethtool -k`)

## References

- Case 04495863 Q4 — enic ntuple confirmation
- Case 03557602 — aRFS degradation on enic
- BZ 2216206 — enic aRFS bug
- Intel X710/XL710 Tuning Guide (doc 334019) — Flow Director
- Broadcom NIC Tune — ntuple and GRO offloads
