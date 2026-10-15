# OpenShift Node Tuning Field Guide

| | |
|---|---|
| **Customer** | IAF — Unit Ofek 324 |
| **Platform** | OpenShift Container Platform 4.16+ |
| **Date** | October 2026 |
| **Author** | Idan Herman, Consultant, PS IGC |
| **Classification** | Customer Confidential |

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | Oct 2026 | Idan Herman | Initial release |
| 2.0 | Oct 2026 | Idan Herman | Restructured: added hardware profiles, NUMA diagnostics, corrected technical accuracy, moved PerformanceProfile to appendix |

---

## Executive Summary

This guide is a comprehensive reference for tuning OpenShift nodes across four configuration layers: **KubeletConfig**, **PerformanceProfile**, **MachineConfig**, and **Node Tuning Operator (TuneD)**. It covers every tunable parameter an OpenShift administrator should consider, with per-parameter analysis of when to change the default, which direction to tune, and how the recommendation varies by node archetype.

**Part 1** provides generic guidance applicable to any OpenShift cluster. **Part 2** documents the customer's current configuration state and observed issues across three hardware types. **Part 3** provides the recommended target configuration and rollout plan.

Four findings require immediate action:

1. **CRITICAL — `podPidsLimit=1024` on infra-kubeletconfig and tuned-worker-kubeletconfig.** This value was deliberately set during the July 2023 CRI-O panic crisis (Case 03548427) as an emergency measure against 10,000+ zombie processes. It did not fix the issue — the real fix was the CRI-O bugfix in 4.12.30 — and was never reverted. In June 2026, it directly caused a Multus thread exhaustion outage on OCP 4.16 (Case 04472910). Raise to 4096 (the OCP 4.11+ default). **Lesson: emergency changes need a revert ticket.**
2. **CRITICAL — `systemReserved.memory=500Mi` on tuned-worker-kubeletconfig.** Red Hat engineering recommended 10Gi for these 756GB bare-metal nodes (Case 03562048). The current value is 20x below that recommendation. Increase to at least 10Gi.
3. **CRITICAL — `net.ipv4.tcp_rmem` TuneD fix for enic bare-metal nodes.** The RHEL 9.4 TCP window auto-tuning regression (KCS 7127975) causes multi-hour container image pulls on Cisco enic NICs. The TuneD fix must be deployed before any workload churn on those nodes.
4. **CRITICAL — Ring buffers at defaults on Dell R6625 and Cisco C220 pizza servers.** 12.7 million `rx_missed_errors` observed on the C220 with ring buffers at 512 (max available: 8160). Dell R6625 also at defaults (511 vs max 2047). Deploy TuneD profiles to increase ring buffers.

Additionally, the **normal-worker pool** runs `maxPods: 500` with `autoSizingReserved: true` and default `kubeAPIQPS: 50`. Auto-sizing reserves only 500m CPU (the enforced minimum) for a workload that needs 4000m+, and the default QPS is too low for 500 pods. This pool needs the same manual `systemReserved` and raised `kubeAPIQPS/Burst` as the tuned-worker pool.

All changes except TuneD profiles require MCO rolling reboots. A phased rollout plan with maintenance windows is provided in §15.

---

# PART 1 — Fundamentals

---

## §1 — Configuration Layers

OpenShift provides four layers for node tuning. Each has different scope, persistence, and reboot requirements:

| Layer | Applied via | Requires reboot? | Scope |
|-------|-----------|-------------------|-------|
| **KubeletConfig** | `machineconfiguration.openshift.io/v1` CR | Yes (MCO rollout) | Kubelet process behavior: pod limits, eviction, system reserves, API rate limits |
| **PerformanceProfile** | `performance.openshift.io/v2` CR | Yes (MCO rollout) | CPU pinning, NUMA topology, hugepages, kernel boot arguments. Generates KubeletConfig + MachineConfig + TuneD behind the scenes. |
| **MachineConfig** | `machineconfiguration.openshift.io/v1` CR | Yes (MCO rollout) | Kernel boot params, systemd units, files on disk, sysctl via `/etc/sysctl.d/` |
| **TuneD (NTO)** | `tuned.openshift.io/v1` CR | **No** — applied live | Kernel sysctls, NIC hardware settings (ring buffers, coalescing, features), CPU governor, C-state restriction |

**Key insight:** TuneD is the only layer that applies without a node reboot. For network tuning, it should be deployed first — the impact is immediate and the risk is lowest.

**PerformanceProfile as a superset:** A PerformanceProfile generates a KubeletConfig, a MachineConfig, and a TuneD profile. If a separate KubeletConfig CR already targets the same MachineConfigPool, the two KubeletConfigs can conflict. When using a PerformanceProfile, put additional kubelet settings in the `kubeletconfig.experimental` annotation on the PerformanceProfile, not in a separate CR.

---

## §2 — System Resource Reservation

**KubeletConfig fields:** `autoSizingReserved`, `systemReserved.cpu`, `systemReserved.memory`, `systemReserved.ephemeral-storage`

### What it does

`systemReserved` carves out CPU, memory, and ephemeral storage from the node's allocatable pool. The scheduler cannot place pods into reserved resources. This protects kubelet, CRI-O, systemd, kernel threads, and other system processes from pod resource pressure.

`autoSizingReserved` (OCP-specific, available since 4.8) calculates these values automatically using a formula based on node capacity. Starting with OCP 4.21, it is enabled by default for new installations.

### The formula (OCP 4.16)

**CPU** (per KCS 5843241):
- 6% of first core + 1% of second + 0.5% of next 2 + 0.25% of remaining
- **Minimum enforced: 500m** regardless of calculation. On a 56-core node the formula yields 210m, but the kubelet applies the 500m floor.

**Memory:**
- 25% of first 4 GiB + 20% of next 4 GiB + 10% of next 8 GiB + 6% of next 112 GiB + 2% of remaining

**Ephemeral storage:** fixed at 1Gi.

### Calculated values for common node sizes

| Node | Cores | RAM | Formula CPU | Enforced CPU | Auto Memory | Auto ES |
|------|-------|-----|------------|-------------|-------------|---------|
| Small VM (general) | 4 | 16 GB | 80m | 500m (min) | 2.6 Gi | 1Gi |
| Medium VM (infra) | 12 | 42 GB | 100m | 500m (min) | 4.2 Gi | 1Gi |
| Large VM (master) | 20 | 130 GB | 120m | 500m (min) | 9.4 Gi | 1Gi |
| Large BM (worker) | 56 | 756 GB | 210m | 500m (min) | 21.9 Gi | 1Gi |

### Per-archetype guidance

| Archetype | Recommendation |
|-----------|---------------|
| **Master VM** | Enable `autoSizingReserved: true`. The auto-calculated values are appropriate for control-plane workloads. |
| **Infra VM** | Enable `autoSizingReserved: true`. Infra nodes run routers and monitoring with predictable resource profiles. |
| **Worker BM (≤250 pods)** | Enable `autoSizingReserved: true`. For standard density, auto-sizing is sufficient. |
| **Worker BM (250–500 pods)** | **Manual tuning required.** Auto-sizing reserves only 500m CPU (the enforced minimum), which is inadequate for high pod counts. Recommended: `cpu: 4000m, memory: 10Gi, ephemeral-storage: 1Gi`. |

### When to go manual vs auto

| Situation | Use auto-sizing | Use manual |
|-----------|----------------|------------|
| Default pod density (≤250) | ✓ | |
| High pod density (250-500) | | ✓ — increase CPU to 4000m+ |
| Latency-sensitive workloads | | ✓ — with PerformanceProfile |
| Large bare-metal nodes (56+ cores) at high density | | ✓ — auto CPU is too low |
| Standard VM nodes | ✓ | |

---

## §3 — Pod Density & Scheduling

**KubeletConfig fields:** `maxPods`, `podPidsLimit`, `kubeAPIQPS`, `kubeAPIBurst`

### maxPods

**Default:** 250. Maximum pods the kubelet will run on a node.

| Value | Typical use case | Considerations |
|-------|-----------------|----------------|
| 110 | Kubernetes default (upstream) | Very conservative |
| 250 | OCP default | Appropriate for most clusters |
| 500 | High-density bare-metal | Requires: hostPrefix /23 or /22, increased systemReserved, increased kubeAPIQPS/Burst |

**Relationship to hostPrefix (clusterNetwork CIDR):**

| hostPrefix | Max pod IPs per node | Safe maxPods |
|------------|---------------------|-------------|
| /24 | 254 | 250 |
| /23 | 510 | 500 |
| /22 | 1022 | 1000 |

`maxPods` must not exceed the IP address space available per node. Changing `hostPrefix` after installation is not supported.

### podPidsLimit

**Default:** 4096 (since OCP 4.11; was 1024 before 4.11). Maximum PIDs (processes/threads) a single pod can spawn, enforced via cgroup `pids.max`.

| Value | Context |
|-------|---------|
| 1024 | Pre-OCP-4.11 default. Insufficient for Go runtime thread accumulation, Java thread pools, Node.js worker threads. |
| 4096 | Current OCP 4.11+ default. Appropriate for most workloads. |
| 8192+ | Only for workloads with extreme thread counts (HPC, large JVMs). |

A `podPidsLimit` set explicitly in a KubeletConfig CR persists through OCP upgrades — the new default only applies to clusters that never set it. This is how KubeletConfig CRs work, not an upgrade bug. Emergency configuration changes need a revert ticket once the root cause is resolved.

### kubeAPIQPS / kubeAPIBurst

**Defaults:** QPS=50, Burst=100. Client-side rate limit for kubelet's requests to the API server.

| maxPods | Recommended QPS | Recommended Burst |
|---------|----------------|-------------------|
| ≤250 | 50 (default) | 100 (default) |
| 250-500 | 100 | 200 |
| 500+ | 150-200 | 300-400 |

**How to detect client-side throttling:** Look for `"Waited for ... due to client-side throttling"` in kubelet logs, or monitor `rest_client_rate_limiter_duration_seconds` in Prometheus. Do **not** rely on HTTP 429 responses — those indicate API *server-side* throttling, and raising the kubelet's client QPS makes that problem *worse*.

---

## §4 — Eviction Management

**KubeletConfig fields:** `evictionHard`, `evictionSoft`, `evictionSoftGracePeriod`, `evictionPressureTransitionPeriod`

### How eviction works

1. **Hard eviction** — When free memory drops below the threshold, kubelet immediately kills the lowest-priority pods (BestEffort first, then Burstable, then Guaranteed).
2. **Soft eviction** — When free memory drops below the threshold for longer than the grace period, kubelet gracefully terminates pods.

**Critical concept:** Hard eviction threshold is subtracted from allocatable:

```
Allocatable = Capacity - systemReserved - kubeReserved - evictionHard
```

The scheduler already accounts for this when placing pods.

### Default vs tuned eviction

| Signal | OCP Default (Hard) | OCP Default (Soft) | Recommended for Worker BM (756GB) |
|--------|-------------------|-------------------|--------------------------|
| `memory.available` | 100Mi | *(not set)* | Hard: 4-8Gi, Soft: 10-16Gi |
| `nodefs.available` | 10% | *(not set)* | Hard: 10%, Soft: 15-20% |
| `nodefs.inodesFree` | 5% | *(not set)* | Hard: 5%, Soft: 10% |
| `imagefs.available` | 15% | *(not set)* | Hard: 10-15%, Soft: 20-25% |

### When to configure soft eviction

Soft eviction is disabled by default. Enable when nodes have large RAM (128GB+) where 100Mi hard threshold provides almost no warning.

**Important:** The kubelet **rejects** a configuration that specifies `evictionSoft` thresholds without corresponding `evictionSoftGracePeriod` entries. Both must be set together.

### Memory eviction and kernel buffers

TuneD network tuning (e.g., `net.core.rmem_max=16777216`) sets a **ceiling** for TCP socket buffer sizes. Actual memory is allocated on demand, not pre-allocated.

On **cgroup v2** (OCP 4.16 default for new installs), kernel socket buffer memory is tracked by the pod's cgroup — the kubelet sees it in eviction accounting. On **cgroup v1** (clusters upgraded from OCP 4.12 may still use this), this memory is **not** tracked and directly reduces "available" memory. Verify: `stat -fc %T /sys/fs/cgroup/` — `cgroup2fs` = v2, `tmpfs` = v1.

### evictionPressureTransitionPeriod

**Default:** 5m0s. After eviction pressure is relieved, kubelet waits this long before removing the condition taint. Prevents oscillation between pressure/no-pressure states.

**Recommendation:** Keep at default (5m0s). Do not set to 0s.

---

## §5 — Image Lifecycle

**KubeletConfig fields:** `imageMinimumGCAge`, `imageGCHighThresholdPercent`, `imageGCLowThresholdPercent`, `nodeStatusMaxImages`

| Parameter | Default | Effect of changing |
|-----------|---------|-------------------|
| `imageGCHighThresholdPercent` | 85 | Lower = GC starts sooner |
| `imageGCLowThresholdPercent` | 80 | Lower = GC frees more space |
| `imageMinimumGCAge` | 2m0s | Higher = images kept longer |

### nodeStatusMaxImages

**Default:** 50. Maximum images reported in node status. Higher values make every Node API object larger — every watcher (scheduler, controllers, monitoring) receives the larger payload. Measure API server impact before setting above 500.

---

## §6 — CPU Topology, NUMA & Pinning

**KubeletConfig fields:** `topologyManagerPolicy`, `topologyManagerScope`, `cpuManagerPolicy`
**PerformanceProfile fields:** `spec.cpu.reserved`, `spec.cpu.isolated`, `spec.numa.topologyPolicy`

### NUMA overview

Modern multi-socket servers have Non-Uniform Memory Access (NUMA). Memory access latency depends on which CPU socket accesses which memory bank. A CPU accessing its local NUMA memory takes ~80ns; cross-socket access adds ~70-150ns depending on the interconnect.

### topologyManagerPolicy

| Policy | Behavior | Use case |
|--------|----------|----------|
| `none` (default) | No NUMA awareness | General-purpose workloads |
| `best-effort` | Tries NUMA alignment, doesn't fail | Mixed workloads |
| `restricted` | Requires NUMA alignment for Guaranteed QoS pods | Latency-sensitive workloads |
| `single-numa-node` | All resources from one NUMA node | Ultra-low-latency, DPDK |

**Important:** `topologyManagerPolicy` only has effect when `cpuManagerPolicy: static` is also set. Without it, the topology manager has no CPU hints to work with and all policies behave like `none`.

### cpuManagerPolicy

| Policy | Behavior | Use case |
|--------|----------|----------|
| `none` (default) | CFS scheduler distributes CPU time. Pods share cores. | General workloads |
| `static` | Guaranteed QoS pods with integer CPU requests get exclusive cores. | Latency-sensitive |

Via KubeletConfig, `static` gives exclusive cores but the kubelet picks **which** cores. To control which cores are reserved vs isolated, use a PerformanceProfile.

### CPU pinning via PerformanceProfile

The PerformanceProfile divides CPUs into:
- **reserved** — System processes (kubelet, CRI-O, systemd, kernel threads, IRQ handlers)
- **isolated** — Workload pods with Guaranteed QoS and integer CPU requests

**Key rules for reserved CPUs:**
- Include **whole physical cores** (both hyperthread siblings)
- Reserve cores from **both NUMA nodes**
- Core 0 always handles boot interrupts — always include it
- Weight extra reserved cores toward the NUMA node where NICs are attached (for DMA locality)
- Verify topology on the node: `oc debug node/<node> -- chroot /host lscpu -p`

### PerformanceProfile vs KubeletConfig

| Need | KubeletConfig | PerformanceProfile |
|------|:---:|:---:|
| `topologyManagerPolicy` | ✓ (needs `cpuManagerPolicy: static`) | ✓ |
| `cpuManagerPolicy: static` (kubelet picks cores) | ✓ | ✓ |
| Control **which** cores are reserved vs isolated | ✗ | ✓ |
| IRQ affinity control | ✗ | ✓ |
| HugePages, RT kernel, C-state boot args | ✗ | ✓ |

**Warning:** A PerformanceProfile generates its own KubeletConfig. Additional kubelet settings must go in the `kubeletconfig.experimental` annotation, not a separate CR.

---

## §7 — NIC, IRQ & Packet Delivery

This section covers how packets flow from the NIC to the application and where tuning matters.

### RSS (Receive Side Scaling)

The NIC distributes incoming packets across multiple RX queues using a header hash. Each queue has its own IRQ assigned to a CPU. RSS does not know which CPU runs the consuming thread — it distributes purely by hash.

### RFS (Receive Flow Steering)

Software-level steering in the softirq path. After RSS delivers a packet, RFS checks which CPU last accessed the flow's socket and steers the packet there. Improves cache locality. Configured via `net.core.rps_sock_flow_entries` and per-queue `rps_flow_cnt`.

### aRFS (Accelerated RFS)

Hardware-assisted RFS. The NIC steers packets directly to the consuming thread's CPU. Requires `ntuple` feature support. Available on bnxt_en and i40e; **not** supported on enic.

### DMA locality

The NIC's DMA ring buffers are in the memory of the NUMA node where the NIC's PCIe root complex is attached. A CPU on the same NUMA node accesses these buffers with local latency (~80ns). A cross-NUMA CPU adds ~70-150ns per access.

### irqbalance

The `irqbalance` service runs on all RHCOS nodes by default. It reads each device's `numa_node` from sysfs and preferentially assigns IRQs to CPUs on the same NUMA node. On all three customer hardware types, irqbalance correctly keeps NIC IRQs on NUMA 0 (where all NICs are attached). This is automatic, not manually configured.

### NAPI and interrupt coalescing

The NIC does **not** fire an IRQ per packet. On the first packet, the NIC fires a hardware IRQ. The IRQ handler disables further interrupts from that queue and schedules NAPI polling. NAPI then pulls packets from the ring buffer in batches (up to `netdev_budget` per cycle) without further interrupts. When the ring is empty, IRQs are re-enabled. Under high load, NAPI polls continuously — effectively interrupt-free.

### C-state impact on IRQ handling

When a CPU is in a deep idle state (C1E=10µs, C2=800µs on AMD EPYC), there is a wake-up delay before it can begin processing an arriving IRQ. During this delay, the ring buffer fills. C-states can be restricted at runtime via TuneD `[cpu] force_latency=1` (no reboot) or permanently via kernel boot arguments.

### Per-driver capability matrix

| Capability | enic (Cisco VIC) | i40e (Intel X710) | bnxt_en (Broadcom) | vmxnet3 (VMware) |
|------------|:---:|:---:|:---:|:---:|
| Ring via TuneD | ✗ (UCSM) | ✓ | ✓ | ✓ |
| Coalesce via TuneD | ✗ (UCSM) | ✓ | ✓ | ✗ |
| ntuple (aRFS) | ✗ (not supported) | ✓ | ✓ | ✗ |
| GRO-HW | ✗ (not supported) | ✗ (off [fixed] on C220) | ✓ | ✗ |
| RSS | via UCSM | auto (1 queue per CPU) | via ethtool | limited |

**enic hardware note:** On Cisco VIC (enic driver), ring buffers, queue count, interrupt coalescing, and RSS are managed at the **UCS adapter policy** level (UCSM for B-series blades, CIMC for C-series rack), not via ethtool or TuneD. The TuneD `[net]` section with `ring=` or `coalesce=` is silently ignored by enic.

---

## §8 — Pod-Level Sysctl Access

**KubeletConfig field:** `allowedUnsafeSysctls`

Several network sysctls including `net.core.somaxconn` and `net.ipv4.tcp_max_syn_backlog` are set **per network namespace**. Each pod gets its own namespace with kernel defaults (e.g., `somaxconn=4096` on RHEL 9). Setting these via TuneD at the host level **only affects host-network pods** (`hostNetwork: true`) and system processes — ordinary pods are unaffected.

This means:
- TuneD's `somaxconn=10240` on infra nodes benefits the OpenShift router (which uses `hostNetwork: true`) but does nothing for regular pods.
- `allowedUnsafeSysctls: [net.core.somaxconn]` in KubeletConfig is needed if non-host-network pods need to override the kernel default. The two settings serve different purposes and are **not redundant**.

### Finding which pods use allowedUnsafeSysctls

```bash
oc get pods,deploy,sts,ds -A -o json | jq -r '
  .items[] |
  (.spec.template.spec // .spec) as $s |
  select($s.securityContext.sysctls) |
  "\(.kind) \(.metadata.namespace)/\(.metadata.name): \([$s.securityContext.sysctls[].name] | join(","))"
'
```

If nothing is returned, the setting is a no-op. It is harmless to leave in place.

---

## §9 — Registry & Image Pull

**KubeletConfig fields:** `registryPullQPS`, `registryBurst`, `serializeImagePulls`

**Defaults:** QPS=5, Burst=10. Rate limit for image pull requests.

| Scenario | Recommended QPS | Recommended Burst |
|----------|----------------|-------------------|
| Standard (≤250 pods) | 5 (default) | 10 (default) |
| High density (250-500 pods) | 20-50 | 40-100 |
| Burst recovery (post-drain) | 50 | 100 |

Keep `serializeImagePulls: false` (default). Parallel pulls are faster.

---

## §10 — Timeouts, Shutdown & Operational

### runtimeRequestTimeout

**Default:** 2m0s. Timeout for CRI-O operations (container create/start/stop). Image pulls are handled separately by CRI-O and are generally **not** subject to this timeout. Fix slow pulls via `registryPullQPS/Burst` or network fixes (e.g., enic `tcp_rmem`).

### shutdownGracePeriod

**Defaults:** Both 0s (graceful shutdown disabled). Enable (60-120s total, 15-30s for critical pods) if nodes are shut down outside of `oc drain`.

### Authentication/Authorization webhook cache

**Defaults:** `cacheTTL: 2m0s`, `cacheAuthorizedTTL: 5m0s`, `cacheUnauthorizedTTL: 30s`. These caches apply to requests **to the kubelet** (metrics server, log collectors). They are not related to `kubeAPIQPS` or pod count. Keep at defaults. Do not set to 0s.

---

## §11 — Parameters You Should NOT Touch

| Parameter | Default | Why leave it alone |
|-----------|---------|-------------------|
| `cgroupDriver` | systemd | Required by OpenShift; changing breaks CRI-O |
| `cgroupsPerQOS` | true | Required for QoS class enforcement |
| `protectKernelDefaults` | false (OCP default) | Set by MCO |
| `failSwapOn` | true | Swap not supported on RHCOS |
| `rotateCertificates` | true | Required for certificate rotation |
| `serverTLSBootstrap` | true | Required for kubelet TLS |
| `enableControllerAttachDetach` | true | Required for volume lifecycle |
| `tlsCipherSuites` | (hardened list) | Security requirement |
| `tlsMinVersion` | VersionTLS12 | Security requirement |
| `enforceNodeAllocatable` | [pods] | Required for resource enforcement |
| `featureGates` | (managed by OCP) | Overwritten by CVO |
| `containerRuntimeEndpoint` | /var/run/crio/crio.sock | CRI-O socket path |
| `systemCgroups` | /system.slice | RHCOS systemd layout |
| `oomScoreAdj` | -999 | Protects kubelet from OOM killer |
| `cpuCFSQuota` | true | Required for CPU limit enforcement |
| `nodeLeaseDurationSeconds` | 40 | Affects NotReady detection timing |

---

# PART 2 — Current State & Issues

---

## §12 — Hardware Inventory

The customer operates three bare-metal hardware types. Diagnostics were collected October 2026 using per-hardware scripts.

### Cisco UCS B200 M5 (blade server)

**Sampled node:** oscp-dev-wrk-5.mamdas.iaf

| Item | Value |
|------|-------|
| CPU | Intel Xeon Gold 6132, 2s × 14c × 2t = 56 logical |
| RAM | 756 GB (376G + 378G) |
| NUMA distance | 10 local / 21 remote |
| NICs | eth0 (20G), iscsi1 (20G, MTU 9000), iscsi2 (20G, MTU 9000), trunk0 (20G, macvlan) |
| NIC driver | enic (Cisco VIC) |
| NIC NUMA | All 4 on NUMA 0 |
| RX queues | 8 per NIC (32 total) |
| Ring buffers | max=4096, current=4096 (set via UCSM adapter policy, NOT TuneD) |
| aRFS | Not supported (off [fixed]) |
| Bond | None |

**NUMA layout:**

```
SOCKET 0 / NUMA 0 (376G)                SOCKET 1 / NUMA 1 (378G)
CPUs 0-13 + HT 28-41                    CPUs 14-27 + HT 42-55

◆ eth0    (enic, 20G, 8rx)
◆ iscsi1  (enic, 20G, MTU 9000)         (no NICs)
◆ iscsi2  (enic, 20G, MTU 9000)
◆ trunk0  (enic, 20G, macvlan)
```

**Observed issues:**

| Finding | Severity | Detail |
|---------|----------|--------|
| Softnet drops | CRITICAL | 22,000–209,000 drops per NUMA 0 CPU. CPU 32 hotspot: 11B packets, 180K drops. |
| Softnet squeezes | WARNING | 6,000–421,000 per CPU. `netdev_budget=600` is insufficient. |
| eth0 rx_no_bufs | WARNING | 4,024 despite ring at max 4096. CPU can't drain fast enough. |
| RFS disabled | INFO | `rps_sock_flow_entries=0`. No packet steering to app CPU. |
| C-states | INFO | C1E dominant (10µs). C6 disabled. |
| podPidsLimit | CRITICAL | Still at 1024. |
| topologyManagerPolicy | WARNING | `best-effort` with `cpuManagerPolicy: none` — no effect. |

**IRQ affinity:** All 72+ enic IRQs correctly pinned to NUMA 0 by irqbalance (automatic, not manually configured).

---

### Dell PowerEdge R6625

**Sampled node:** oscp-dell-wrk-1 (fresh cluster, no production workload)

| Item | Value |
|------|-------|
| CPU | AMD EPYC 9334, 2s × 32c × 2t = 128 logical |
| RAM | 1,511 GB (755G + 756G) |
| NUMA | 2 nodes (NPS1), distance 10/32 |
| NICs | 4× Broadcom bnxt_en 25G |
| NIC NUMA | All NUMA 0 |
| Ring buffers | max=2047, current=511 (DEFAULT) |
| aRFS | ON. GRO-HW: ON. |
| Bond | trunk0: 802.3ad LACP (np0 + np1) |

**NUMA layout:**

```
SOCKET 0 / NUMA 0 (755G)                SOCKET 1 / NUMA 1 (756G)
CPUs 0-31 + HT 64-95                    CPUs 32-63 + HT 96-127

◆ eno12399np0 (bnxt_en, 25G) ─┐
◆ eno12409np1 (bnxt_en, 25G) ─┤ trunk0       (no NICs)
◆ eno12419np2 (bnxt_en, 25G)  │
◆ eno12429np3 (bnxt_en, 25G)  │
```

**Observed state:** Zero softnet drops/squeezes (expected — fresh cluster). Ring buffers at defaults. C2 state at 800µs latency (AMD EPYC deep sleep). podPidsLimit correct at 4096.

---

### Cisco UCS C220-M5SX (pizza/rack server)

**Sampled node:** oscp-58p-wrk2

| Item | Value |
|------|-------|
| CPU | Intel Xeon Gold 6226R, 2s × 16c × 2t = 64 logical |
| RAM | 252 GB (126G + 126G) |
| NUMA distance | 10 local / 21 remote |
| NICs | eth0 + eth1 (i40e, 10G, 64 RX queues each) |
| NIC NUMA | All NUMA 0 |
| Ring buffers | max=8160, current=512 (DEFAULT) |
| Bond | bond0: 802.3ad LACP (eth0 + eth1) |

**NUMA layout:**

```
SOCKET 0 / NUMA 0 (126G)                SOCKET 1 / NUMA 1 (126G)
CPUs 0-15 + HT 32-47                    CPUs 16-31 + HT 48-63

◆ eth0 (i40e, 10G, 64rx) ─┐
◆ eth1 (i40e, 10G, 64rx) ─┤ bond0         (no NICs)
```

**Observed issues:**

| Finding | Severity | Detail |
|---------|----------|--------|
| rx_missed_errors on eth0 | CRITICAL | **12,743,206** — ring buffer overflow at default 512. Max available: 8160. |
| CRC errors on eth1 | WARNING | 31,247 — physical layer issue (bad cable/SFP). Run `ethtool -m eth1`. |
| Ring buffers | CRITICAL | All at defaults (512). Direct cause of 12.7M rx_missed_errors. |
| podPidsLimit | CRITICAL | Still at 1024. |

**64 RX queues:** i40e creates one queue per CPU (64 queues on 64 CPUs). No channel tuning needed.

---

### Hardware comparison summary

| | Cisco B200 M5 | Dell R6625 | Cisco C220-M5SX |
|---|---|---|---|
| CPU | Xeon Gold 6132 (56) | EPYC 9334 (128) | Xeon Gold 6226R (64) |
| RAM | 756 GB | 1,511 GB | 252 GB |
| NIC | enic 20G | bnxt_en 25G | i40e 10G |
| Ring buf config | **UCSM** | TuneD | TuneD |
| Ring buf current | 4096 (maxed) | 511 (DEFAULT) | 512 (DEFAULT) |
| aRFS | Not supported | ON | Verify |
| Softnet drops | MASSIVE | Zero (baseline) | Zero |
| rx_missed/no_bufs | 4,024 | 138 | **12,743,206** |
| podPidsLimit | **1024** | 4096 | **1024** |
| NIC NUMA | All NUMA 0 | All NUMA 0 | All NUMA 0 |
| IRQ NUMA | Correct (auto) | Correct (auto) | Correct (auto) |

**Common pattern:** On all three hardware types, all NICs are on NUMA 0 and irqbalance correctly keeps IRQs on NUMA 0 CPUs automatically.

---

## §13 — KubeletConfig Divergence

Baseline: live kubelet configz from a vanilla OCP 4.16.49 worker (no KubeletConfig CR applied).

### Case Archive Lore

Historical support cases that explain why specific settings were chosen (83 cases cross-referenced):

**Case 03548427 — PLEG / CRI-O Panic (OCP 4.12, Jun–Sep 2023).** The "master reference" case. After upgrading from 4.12.2 to 4.12.15, workers went NotReady with CRI-O panics. Timeline: Jul 2 — PS consultant set podPidsLimit=1024 against 10,000+ zombie processes. Jul 5 — "still faced the issue." Jul 6 — raised kubeAPIQPS to 100, kubeAPIBurst to 200, reduced maxPods to 400. Root cause: CRI-O race condition (OCPBUGS-15868), fixed in 4.12.30.

**Case 03562048 — Manual Node Sizing (Jul 2023).** Engineering recommended `systemReserved: cpu: 4000m, memory: 10Gi`. CPU was adopted. Memory was not — current value is 500Mi (20x below recommendation).

**Case 03703812 — Kubelet GC Under Load (Jan 2024).** kubelet consumed 6+ CPU cores under GC pressure with maxPods=500. Confirms 4000m CPU reservation is justified.

**Case 04046963 — Pod Startup Delay (Jan–Mar 2025).** Confirmed systemReserved.memory was already at 500Mi. Configured registryPullQPS: 50, registryBurst: 100.

**Case 04472910 — Multus Thread Exhaustion (OCP 4.16, Jun 2026).** Multus hit pids.max=1024 during OVS/OVN stalls. Recommended raising podPidsLimit to 4096 immediately.

### Per-Pool Divergence Tables

**infra-kubeletconfig** — 5 divergences:

| Field | Default | Value | Severity | Notes |
|-------|---------|-------|----------|-------|
| `autoSizingReserved` | false | true | INFO | Correct |
| `allowedUnsafeSysctls` | none | net.core.somaxconn | INFO | Enables pod-level override |
| `maxPods` | 250 | 100 | INFO | Appropriate for infra |
| `nodeStatusMaxImages` | 50 | 250 | INFO | |
| `podPidsLimit` | 4096 | **1024** | **CRITICAL** | Caused Multus failure on 4.16 |

**normal-worker-kubeletconfig** — 3 divergences:

| Field | Default | Value | Severity | Notes |
|-------|---------|-------|----------|-------|
| `autoSizingReserved` | false | true | **WARNING** | Only 500m CPU for 500-pod node |
| `allowedUnsafeSysctls` | none | net.core.somaxconn | INFO | |
| `maxPods` | 250 | 500 | **WARNING** | Default kubeAPIQPS=50 too low |

**tuned-worker-kubeletconfig** — 23 divergences + 14 dump artifacts:

| Field | Default | Value | Severity | Notes |
|-------|---------|-------|----------|-------|
| `systemReserved.cpu` | 500m | 4000m | INFO | Correctly adopted |
| `systemReserved.memory` | 1Gi | **500Mi** | **CRITICAL** | Engineering recommended 10Gi |
| `systemReserved.ephemeral-storage` | 1Gi | not set | WARNING | Lost when switching to manual |
| `podPidsLimit` | 4096 | **1024** | **CRITICAL** | Emergency measure, never reverted |
| `topologyManagerPolicy` | none | best-effort | WARNING | No-op without `cpuManagerPolicy: static` |
| `kubeAPIQPS` / `kubeAPIBurst` | 50/100 | 100/200 | INFO | Correctly raised |

Plus 14 zero-value config dump artifacts (all `0s`/`0`) that should be removed. The kubelet replaces these with compiled defaults so they are currently harmless but add noise.

### systemReserved Gap Analysis

| Source | CPU | Memory | ES |
|--------|-----|--------|---|
| Auto-sizing (formula) | 210m → enforced 500m | 22 Gi | 1Gi |
| RH Engineering (Case 03562048) | 4000m | 10 Gi | 1Gi |
| OCP static default | 500m | 1 Gi | 1Gi |
| **Customer actual** | 4000m | **500 Mi** | **not set** |

Memory: 45x below auto-sizing, 20x below recommendation, 2x below OCP default.

---

## §14 — TuneD Assessment

| Profile | Target | Status |
|---------|--------|--------|
| baremetal-cisco-b200 | Cisco blades (enic) | **Partially deployed.** tcp_rmem CRITICAL fix must be applied. Ring/coalesce managed by UCSM. |
| baremetal-cisco-c220 | Cisco pizza (i40e) | **Not deployed.** Ring buffers at defaults → 12.7M rx_missed_errors. |
| baremetal-dell-r6625 | Dell R6625 (bnxt_en) | **Not deployed.** Ring buffers at defaults. |
| vm-infra, vm-worker, vm-control-plane | VMs | Ready |

**Gaps not addressed by any current profile:**

| Gap | Impact | Fix |
|-----|--------|-----|
| RFS not configured | Packets stay on IRQ CPU, no steering to app CPU | TuneD sysctl (only useful on enic; Dell/i40e have hardware aRFS) |
| C-state restriction | C1E 10µs / C2 800µs wake-up delay | TuneD `[cpu] force_latency=1` (apply after ring buffer fixes if drops persist) |
| netdev_budget | 600 causes massive squeezes on blades | Consider raising to 1200 in enic profile |

---

# PART 3 — Recommended Configuration

---

## §15 — Rollout Plan

### Phase 1: TuneD Profiles (no reboot, immediate effect)

| Action | Profile | Target | Risk |
|--------|---------|--------|------|
| Deploy enic tcp_rmem fix | baremetal-cisco-b200 | Cisco blade workers | Low |
| Deploy i40e ring+coalesce | baremetal-cisco-c220 | Cisco pizza workers | Low |
| Deploy bnxt_en ring+features | baremetal-dell-r6625 | Dell R6625 workers | Low |
| Deploy VM profiles | vm-infra, vm-worker, vm-control-plane | All VMs | Low |

**Pre-requisite:** Label nodes:
```
oc label node <name> node.kubernetes.io/nic-driver=enic      # Cisco blades
oc label node <name> node.kubernetes.io/nic-driver=i40e       # Cisco pizza
oc label node <name> node.kubernetes.io/nic-driver=bnxt_en    # Dell R6625
```

### Phase 2: KubeletConfig Fixes (MCO rolling reboot per pool)

Batch changes per pool to minimize reboots:

| Action | Pool |
|--------|------|
| Raise podPidsLimit to 4096 | infra-kubeletconfig |
| Raise podPidsLimit to 4096 + systemReserved.memory to 10Gi + add ephemeral-storage + remove 14 dump artifacts + remove topologyManagerPolicy | tuned-worker-kubeletconfig |
| Raise kubeAPIQPS/Burst to 100/200 | normal-worker-kubeletconfig |

---

## §16 — Target KubeletConfigs

### master-kubeletconfig (no changes)

```yaml
kind: KubeletConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: master-kubeletconfig
spec:
  autoSizingReserved: true
  machineConfigPoolSelector:
    matchLabels:
      kubelet: master-kubeletconfig
```

### infra-kubeletconfig (fix podPidsLimit)

```yaml
kind: KubeletConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: infra-kubeletconfig
spec:
  autoSizingReserved: true
  kubeletConfig:
    allowedUnsafeSysctls:
      - net.core.somaxconn
    maxPods: 100
    nodeStatusMaxImages: 250
    podPidsLimit: 4096            # was 1024 — FIXED
  machineConfigPoolSelector:
    matchLabels:
      kubelet: infra-kubeletconfig
```

### normal-worker-kubeletconfig (add QPS)

```yaml
kind: KubeletConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: normal-worker-kubeletconfig
spec:
  autoSizingReserved: true
  kubeletConfig:
    allowedUnsafeSysctls:
      - net.core.somaxconn
    maxPods: 500
    kubeAPIQPS: 100               # ADDED
    kubeAPIBurst: 200             # ADDED
  machineConfigPoolSelector:
    matchLabels:
      kubelet: normal-worker-kubeletconfig
```

### tuned-worker-kubeletconfig (clean rewrite)

Replace entirely. All dump artifacts removed. All values intentional.

```yaml
kind: KubeletConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: tuned-worker-kubeletconfig
spec:
  kubeletConfig:
    maxPods: 500
    podPidsLimit: 4096                      # was 1024 — FIXED
    kubeAPIQPS: 100
    kubeAPIBurst: 200
    nodeStatusMaxImages: 500
    systemReserved:
      cpu: 4000m
      memory: 10Gi                          # was 500Mi — FIXED
      ephemeral-storage: 1Gi               # was missing — ADDED
    evictionHard:
      memory.available: 8Gi
      imagefs.available: 10%
      nodefs.available: 10%
      nodefs.inodesFree: 5%
    evictionSoft:
      memory.available: 16Gi
      imagefs.available: 25%
      nodefs.available: 20%
      nodefs.inodesFree: 15%
      imagefs.inodesFree: 10%
    evictionSoftGracePeriod:
      memory.available: 1m30s
      imagefs.available: 1m30s
      nodefs.available: 1m30s
      nodefs.inodesFree: 1m30s
      imagefs.inodesFree: 1m30s
    imageGCHighThresholdPercent: 75
    imageGCLowThresholdPercent: 50
    imageMinimumGCAge: 5m
    registryPullQPS: 50
    registryBurst: 100
    allowedUnsafeSysctls:
      - net.core.somaxconn
    shutdownGracePeriod: 90s
    shutdownGracePeriodCriticalPods: 15s
  machineConfigPoolSelector:
    matchLabels:
      kubelet: tuned-worker-kubeletconfig
```

---

## §17 — Target TuneD Profiles

| Profile | Driver | Ring | Key settings |
|---------|--------|------|-------------|
| baremetal-cisco-b200 | enic | N/A (UCSM) | tcp_rmem fix, backlog=5000, budget=600 |
| baremetal-cisco-c220 | i40e | 8160 | coalesce=125µs, ntuple on, GRO-HW on, backlog=5000 |
| baremetal-dell-r6625 | bnxt_en | 2047 | coalesce=adaptive, ntuple on, GRO-HW on, backlog=5000 |

---

## §18 — Hardware-Level Configuration

### Cisco UCS (UCSM for B-series blades)

Ring buffers, queue count, RSS, and interrupt coalescing are managed at the UCSM adapter policy level for enic (VIC) NICs. Current values (ring=4096, queues=8, coalesce=125µs, RSS=on) are correct.

For C220 pizza servers using i40e (Intel X710), these settings are managed via TuneD/ethtool — CIMC adapter policy does not apply.

### Dell (iDRAC)

No NIC-level configuration needed in iDRAC for bnxt_en. All settings managed via TuneD.

**BIOS NPS setting:** Verify NPS1 (NUMA-per-socket = 1) is configured: iDRAC → BIOS → Processor Settings → NUMA Nodes Per Socket = 1.

---

# Appendices

---

## Appendix A — PerformanceProfile Reference (FUTURE)

PerformanceProfiles are **not required** for the customer's current issues. All critical fixes (podPidsLimit, systemReserved, ring buffers, tcp_rmem) are addressed by KubeletConfig and TuneD changes. PerformanceProfiles would be a future performance optimization if latency-sensitive workloads are onboarded.

Pre-calculated CPU pinning layouts for when ready:

### Cisco B200 M5 (56 logical CPUs)

```yaml
spec:
  cpu:
    # Socket 0 (NIC NUMA): 6 phys cores + HT = 12 logical
    # Socket 1: 2 phys cores + HT = 4 logical
    reserved: "0-5,14-15,28-33,42-43"
    isolated: "6-13,16-27,34-41,44-55"
  numa:
    topologyPolicy: "restricted"
```

**Rationale:** All 4 NICs + iSCSI on NUMA 0. 32 RX queues fire IRQs there. kubelet GC spikes to 6+ cores.

### Dell R6625 (128 logical CPUs)

```yaml
spec:
  cpu:
    reserved: "0-3,32-33,64-67,96-97"    # 12 logical
    isolated: "4-31,34-63,68-95,98-127"   # 116 logical
```

### Cisco C220-M5SX (64 logical CPUs)

```yaml
spec:
  cpu:
    reserved: "0-3,16-17,32-35,48-49"    # 12 logical
    isolated: "4-15,18-31,36-47,50-63"    # 52 logical
```

### MCP integration

PerformanceProfiles need a `machineConfigPoolSelector`. Since the customer uses per-node MCPs, add a hardware-type label to each per-node MCP and include that role in the MCP's `machineConfigSelector`:

```bash
# Label per-node MCPs
oc label mcp worker-node01 hw-type=cisco-b200

# Patch machineConfigSelector to pick up generated MCs
oc patch mcp worker-node01 --type=json -p '[{"op":"add","path":"/spec/machineConfigSelector/matchExpressions/0/values/-","value":"cisco-b200"}]'
```

---

## Appendix B — Case Archive Summary

| Case | Date | OCP | Topic | Settings Affected |
|------|------|-----|-------|-------------------|
| 03502380 | May 2023 | 4.8 | Eviction best practices | evictionSoft, evictionHard |
| 03548427 | Jun–Sep 2023 | 4.12 | PLEG / CRI-O panic | podPidsLimit, maxPods, kubeAPIQPS/Burst |
| 03562048 | Jul 2023 | 4.12 | Manual node sizing | systemReserved (10Gi recommended) |
| 03703812 | Jan 2024 | 4.12 | Kubelet GC under load | systemReserved.cpu (6+ cores) |
| 04046963 | Jan–Mar 2025 | 4.12 | Pod startup after drain | systemReserved (500Mi confirmed) |
| 04472910 | Jun 2026 | 4.16 | Multus thread exhaustion | podPidsLimit (1024 → failure) |

---

## Appendix C — Diagnostic Scripts

Per-hardware NUMA/NIC diagnostic scripts are available:

| Script | Target hardware | Key checks |
|--------|----------------|------------|
| `numa-diag-cisco-b200.sh` | Cisco UCS B200 M5 blades | NUMA, HT siblings, enic IRQ mapping, softnet, C-states, ring buffers |
| `numa-diag-cisco-c220.sh` | Cisco UCS C220-M5SX pizza | Auto-detects NICs, bonds, HW model |
| `numa-diag-dell.sh` | Dell PowerEdge R6625/R7625 | AMD EPYC NUMA, bnxt_en features, bonds, HW model |

Run via: `oc debug node/<node> -- chroot /host bash` then paste the script.

---

## Appendix D — References

- KCS 5843241 — CPU and memory reservation for OpenShift 4 nodes (https://access.redhat.com/solutions/5843241)
- KCS 7127975 — RHEL 9.4 TCP window regression, enic driver (https://access.redhat.com/solutions/7127975)
- OCPBUGS-15868 — CRI-O race condition, fixed in 4.12.30 (https://issues.redhat.com/browse/OCPBUGS-15868)
- RHSA-2023:4671 — CRI-O security advisory (https://access.redhat.com/errata/RHSA-2023:4671)
- OCPBUGS-27126 — High kubelet CPU usage (https://issues.redhat.com/browse/OCPBUGS-27126)
- golang/go#14592 — Go runtime idle thread accumulation (https://github.com/golang/go/issues/14592)
- Kubernetes Node Allocatable (https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
- OCP PerformanceProfile API (https://docs.openshift.com/container-platform/4.16/scalability_and_performance/cnf-low-latency-tuning.html)
- KCS 5532341 — PerformanceProfile kubeletconfig.experimental annotation (https://access.redhat.com/solutions/5532341)
