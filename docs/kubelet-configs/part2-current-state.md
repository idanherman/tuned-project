# PART 2 — Current State & Issues

---

## §12 — Hardware Inventory

The customer operates four bare-metal hardware types across multiple clusters. Each type has a distinct NUMA topology, NIC driver, and tuning profile. Diagnostics were collected in October 2026 using per-hardware scripts.

### Cisco UCS B200 M5 (blade server)

**Sampled node:** oscp-dev-wrk-5.mamdas.iaf

| Item | Value |
|------|-------|
| CPU | Intel Xeon Gold 6132, 2 sockets × 14 cores × 2 threads = 56 logical |
| RAM | 756 GB (376G + 378G per NUMA node) |
| NUMA distance | 10 local / 21 remote |
| NICs | eth0 (20G), iscsi1 (20G, MTU 9000), iscsi2 (20G, MTU 9000), trunk0 (20G, macvlan) |
| NIC driver | enic (Cisco VIC) |
| NIC NUMA | All 4 on NUMA 0 |
| RX queues | 8 per NIC (32 total) |
| Ring buffers | max=4096, current=4096 (set via UCS adapter policy, NOT ethtool/TuneD) |
| aRFS (ntuple) | Not supported (off [fixed]) |
| GRO-HW | Not supported (off [fixed]) |
| Bond | None |

**NUMA layout:**

```
SOCKET 0 / NUMA 0 (376G)                SOCKET 1 / NUMA 1 (378G)
CPUs 0-13 + HT 28-41                    CPUs 14-27 + HT 42-55

◆ eth0    (enic, 20G, 8rx)
◆ iscsi1  (enic, 20G, 8rx, MTU 9000)    (no NICs)
◆ iscsi2  (enic, 20G, 8rx, MTU 9000)
◆ trunk0  (enic, 20G, 8rx)
```

**HT sibling pairs:** Socket 0: [0,28] [1,29] ... [13,41]. Socket 1: [14,42] [15,43] ... [27,55].

**Observed issues:**

| Finding | Severity | Detail |
|---------|----------|--------|
| Softnet drops | CRITICAL | 22,000–209,000 drops per NUMA 0 CPU. CPU 32 hotspot: 11B packets, 180K drops. Zero drops on NUMA 1. |
| Softnet squeezes | WARNING | 6,000–421,000 per CPU. netdev_budget=600 is insufficient. |
| eth0 rx_no_bufs | WARNING | 4,024 — ring buffer overflow despite ring at max 4096. CPU can't drain fast enough. |
| RFS disabled | INFO | rps_sock_flow_entries=0. Packets stay on IRQ CPU, no steering to app thread. |
| C-states | INFO | C1E dominant (10µs, 34B entries). C6 disabled. |
| podPidsLimit | CRITICAL | Still at 1024 |
| topologyManagerPolicy | WARNING | Set to best-effort but cpuManagerPolicy is none — the setting has no effect |

**IRQ affinity:** All 72+ enic IRQs correctly pinned to NUMA 0 by irqbalance. No cross-NUMA DMA penalty. irqbalance reads the NIC's numa_node=0 from sysfs and keeps IRQs local automatically.

**Hardware configuration note:** On enic (Cisco VIC), ring buffers, queue count, interrupt coalescing, and RSS are managed at the **UCS adapter policy** level (UCSM for B-series blades), not via ethtool or TuneD. The TuneD `[net]` section cannot change these settings. The current values (ring=4096, queues=8, coalesce=125µs) were configured in UCSM.

---

### Dell PowerEdge R6625

**Sampled node:** oscp-dell-wrk-1 (fresh cluster, no production workload)

| Item | Value |
|------|-------|
| CPU | AMD EPYC 9334, 2 sockets × 32 cores × 2 threads = 128 logical |
| RAM | 1,511 GB (755G + 756G per NUMA node) |
| NUMA | 2 nodes (NPS1 BIOS setting) |
| NUMA distance | 10 local / 32 remote (higher than Intel) |
| NICs | 4× Broadcom 25G (bnxt_en): eno12399np0, eno12409np1, eno12419np2, eno12429np3 |
| NIC NUMA | All 4 on NUMA 0 |
| RX queues | 8 per NIC |
| Ring buffers | max=2047, current=511 (DEFAULT — not tuned) |
| aRFS (ntuple) | Supported and ON |
| GRO-HW | Supported and ON |
| Bond | trunk0: 802.3ad LACP (eno12399np0 + eno12409np1) |
| Management NICs | eno8303, eno8403 (tg3, down) |

**NUMA layout:**

```
SOCKET 0 / NUMA 0 (755G)                SOCKET 1 / NUMA 1 (756G)
CPUs 0-31 + HT 64-95                    CPUs 32-63 + HT 96-127

◆ eno12399np0 (bnxt_en, 25G) ─┐
◆ eno12409np1 (bnxt_en, 25G) ─┤ trunk0 (LACP bond)
◆ eno12419np2 (bnxt_en, 25G)  │         (no NICs)
◆ eno12429np3 (bnxt_en, 25G)  │
◇ eno8303 (tg3, mgmt, down)   │
◇ eno8403 (tg3, mgmt, down)   │
```

**HT sibling pairs:** Socket 0: [0,64] [1,65] ... [31,95]. Socket 1: [32,96] [33,97] ... [63,127].

**Observed state (baseline — no production workload):**

| Finding | Severity | Detail |
|---------|----------|--------|
| Softnet drops | None | Zero across all 128 CPUs (expected — fresh cluster) |
| Softnet squeezes | None | Zero (expected) |
| Ring buffers | WARNING | At defaults (511) — max is 2047. Must be raised before production load. |
| NIC discards | INFO | np0: 138 rx_discards, np1: 121 rx_discards. cos4 discards ~6500. Likely pause frame related. |
| C-states | INFO | C2 at 800µs latency is enabled (2.8M entries). Much deeper sleep than Intel C1E. No impact at zero load, but monitor under production traffic. |
| RFS | INFO | Not configured (rps_sock_flow_entries=0). Less critical since aRFS is available at hardware level. |
| podPidsLimit | OK | 4096 (correct) |

**IRQ affinity:** All 42 NIC IRQs on NUMA 0. irqbalance NUMA-aware.

**Key advantage over enic:** bnxt_en supports aRFS (ntuple) and hardware GRO. The NIC can steer packets directly to the CPU running the consuming thread — no RFS redirect cost. The TuneD profile should preserve these features (`features=ntuple on rx-gro-hw on`).

---

### Cisco UCS C220-M5SX (pizza/rack server)

**Sampled node:** oscp-58p-wrk2

| Item | Value |
|------|-------|
| CPU | Intel Xeon Gold 6226R, 2 sockets × 16 cores × 2 threads = 64 logical |
| RAM | 252 GB (126G + 126G per NUMA node) |
| NUMA distance | 10 local / 21 remote |
| NICs | eth0 + eth1 (i40e, 10G, 64 RX queues each), eno2 (ixgbe, down), ens1f2 + ens1f3 (i40e, down) |
| NIC driver | i40e (Intel X710) — active; ixgbe (Intel X520) — unused |
| NIC NUMA | All on NUMA 0 |
| RX queues | 64 per NIC (1 queue per CPU — optimal, no channel tuning needed) |
| Ring buffers | max=8160, current=512 (DEFAULT — not tuned) |
| aRFS (ntuple) | Off on ixgbe; likely supported on i40e (verify with ethtool -k eth0) |
| Bond | bond0: 802.3ad LACP (eth0 + eth1) |

**NUMA layout:**

```
SOCKET 0 / NUMA 0 (126G)                SOCKET 1 / NUMA 1 (126G)
CPUs 0-15 + HT 32-47                    CPUs 16-31 + HT 48-63

◆ eth0  (i40e, 10G, 64rx) ─┐
◆ eth1  (i40e, 10G, 64rx) ─┤ bond0 (LACP)
◇ eno2  (ixgbe, down)      │            (no NICs)
◇ ens1f2 (i40e, down)      │
◇ ens1f3 (i40e, down)      │
```

**HT sibling pairs:** Socket 0: [0,32] [1,33] ... [15,47]. Socket 1: [16,48] [17,49] ... [31,63].

**Observed issues:**

| Finding | Severity | Detail |
|---------|----------|--------|
| rx_missed_errors on eth0 | CRITICAL | **12,743,206** — ring buffer overflow. Ring at default 512, max available 8160 (16x increase available). |
| CRC errors on eth1 | WARNING | 31,247 rx_crc_errors + port.rx_crc_errors — physical layer issue. Bad cable, dirty SFP, or failing transceiver. Not a tuning problem. Run `ethtool -m eth1` for SFP diagnostics. |
| Ring buffers | CRITICAL | All at defaults (512). The 12.7M rx_missed_errors is a direct consequence. |
| Softnet squeezes | INFO | 1,200–2,400 on NUMA 0 CPUs, 280–370 on NUMA 1. Moderate — no drops. |
| C-states | INFO | C1E dominant (10µs, 16B entries). C6 disabled. Same as the blades. |
| RFS | INFO | Not configured. |
| podPidsLimit | CRITICAL | Still at 1024 |
| topologyManagerPolicy | WARNING | best-effort with cpuManagerPolicy: none — no effect |

**IRQ affinity:** All NIC IRQs on NUMA 0 CPUs. irqbalance NUMA-aware.

**64 RX queues:** The i40e driver creates one queue per CPU by default. With 64 CPUs, this gives perfect 1:1 queue-to-CPU mapping. No channel tuning needed (unlike enic with 8 queues for 56 CPUs).

---

### Hardware comparison summary

| | Cisco B200 M5 (blade) | Dell R6625 | Cisco C220-M5SX (pizza) |
|---|---|---|---|
| CPU | Xeon Gold 6132 (56) | EPYC 9334 (128) | Xeon Gold 6226R (64) |
| RAM | 756 GB | 1,511 GB | 252 GB |
| NIC | enic 20G | bnxt_en 25G | i40e 10G |
| Ring buf setting | **UCSM adapter policy** | TuneD/ethtool | TuneD/ethtool |
| Ring buf current | 4096 (maxed) | 511 (DEFAULT) | 512 (DEFAULT) |
| aRFS | Not supported | ON | Verify on i40e |
| GRO-HW | Not supported | ON | Off on ixgbe |
| Softnet drops | MASSIVE | Zero (baseline) | Zero |
| rx_missed/no_bufs | 4,024 | 138 (discards) | **12,743,206** |
| podPidsLimit | **1024** | 4096 | **1024** |
| NIC NUMA | All NUMA 0 | All NUMA 0 | All NUMA 0 |
| IRQ affinity | NUMA-correct | NUMA-correct | NUMA-correct |

**Common pattern:** On all three hardware types, all NICs are on NUMA 0 and irqbalance correctly keeps IRQs on NUMA 0 CPUs. This is automatic behavior (irqbalance reads numa_node from sysfs), not manual configuration.

---

## §13 — KubeletConfig Divergence

*[Move existing Appendix A content here — per-pool divergence tables, case lore timeline, systemReserved gap analysis, zero-value dump artifacts, per-pool recommendations]*

---

## §14 — TuneD Assessment

### Currently deployed

| Profile | Target | Status |
|---------|--------|--------|
| baremetal-cisco-b200 | Cisco blades (enic driver) | **Partially deployed.** tcp_rmem fix is CRITICAL and must be applied. Ring/coalesce managed by UCSM. |
| baremetal-cisco-c220 | Cisco pizza (i40e driver) | **Not deployed.** Ring buffers at defaults causing 12.7M rx_missed_errors. |
| baremetal-dell-r6625 | Dell R6625 (bnxt_en driver) | **Not deployed.** Ring buffers at defaults. aRFS/GRO-HW already on but ring needs increase. |
| vm-infra | Infra VMs | Ready |
| vm-worker | Worker VMs | Ready |
| vm-control-plane | Control plane VMs | Ready |

### What's not configured anywhere

| Gap | Impact | Fix |
|-----|--------|-----|
| RFS (Receive Flow Steering) | Packets stay on IRQ CPU instead of being steered to app CPU. Reduces cache locality. | TuneD sysctl: net.core.rps_sock_flow_entries=32768 + per-queue rps_flow_cnt. Only useful on enic (no aRFS). Dell/i40e have hardware aRFS. |
| C-state restriction | C1E (10µs) or C2 (800µs on EPYC) wake-up latency adds delay to IRQ handling under bursty traffic. | TuneD [cpu] force_latency=1 (runtime, no reboot). Apply only if drops persist after ring buffer fixes. |
| netdev_budget increase | Budget=600 causes massive squeezes on Cisco blades (6K–421K per CPU). | Raise to 1200 or 2400 in enic TuneD profile. Trade-off: higher softirq latency for other tasks. |
