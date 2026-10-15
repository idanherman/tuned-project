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

---

## Executive Summary

This guide is a comprehensive reference for tuning OpenShift nodes across four configuration layers: **KubeletConfig**, **PerformanceProfile**, **MachineConfig**, and **Node Tuning Operator (TuneD)**. It covers every tunable parameter an OpenShift administrator should consider, with per-parameter analysis of when to change the default, which direction to tune, and how the recommendation varies by node archetype.

Three findings require immediate action. Each change requires an MCO rolling reboot of the affected MachineConfigPool, so a rollout plan with maintenance windows is needed.

1. **CRITICAL — `podPidsLimit=1024` on infra-kubeletconfig and tuned-worker-kubeletconfig.** This value was deliberately set during the July 2023 CRI-O panic crisis (Case 03548427) as an emergency measure against 10,000+ zombie processes. It did not fix the issue — the real fix was the CRI-O bugfix in 4.12.30 — and was never reverted. In June 2026, it directly caused a Multus thread exhaustion outage on OCP 4.16 (Case 04472910). Raise to 4096 (the OCP 4.11+ default). **Lesson: emergency changes need a revert ticket.**
2. **CRITICAL — `systemReserved.memory=500Mi` on tuned-worker-kubeletconfig.** Red Hat engineering recommended 10Gi for these 756GB bare-metal nodes (Case 03562048). The current value is 20x below that recommendation. Increase to at least 10Gi.
3. **CRITICAL — `net.ipv4.tcp_rmem` TuneD fix for enic bare-metal nodes.** The RHEL 9.4 TCP window auto-tuning regression (KCS 7127975) causes multi-hour container image pulls on Cisco enic NICs. The TuneD fix must be deployed before any workload churn on those nodes.

Additionally, the **normal-worker pool** runs `maxPods: 500` with `autoSizingReserved: true` and default `kubeAPIQPS: 50`. Per this guide's own rules (§1 and §2), that pool is under-provisioned: auto-sizing reserves only 500m CPU (the enforced minimum) for a workload that needs 4000m+, and the default QPS is too low for 500 pods. This pool needs the same manual `systemReserved` and raised `kubeAPIQPS/Burst` as the tuned-worker pool.

---

## How to Use This Guide

### Node Archetypes

This guide uses two axes to determine tuning recommendations:

| Axis | Options | Impact on tuning |
|------|---------|-----------------|
| **Role** | control-plane, infra, worker | Workload type, pod density, criticality |
| **Hardware** | VM (4–20 cores, 16–130GB) or BM (56+ cores, 756GB+) | NUMA topology, systemReserved sizing, NIC driver tuning, C-states |

The customer's four KubeletConfig pools:

| Pool | Role | HW | Cores | RAM | maxPods | Key differences |
|------|------|----|-------|-----|---------|----------------|
| master-kubeletconfig | control-plane | VM | 20 | 130GB | 250 | autoSizingReserved only |
| infra-kubeletconfig | infra | VM | 12 | 42GB | 100 | podPidsLimit=1024 (CRITICAL) |
| normal-worker-kubeletconfig | worker | BM | 56 | 756GB | 500 | autoSizingReserved + maxPods=500 but default QPS (WARNING) |
| tuned-worker-kubeletconfig | worker | BM | 56 | 756GB | 500 | Manual systemReserved, custom eviction, 14 config-dump artifacts |

Throughout this guide, per-archetype guidance uses these labels:

- **Master VM** — control-plane virtual machines
- **Infra VM** — infrastructure virtual machines (routers, monitoring)
- **Worker BM** — bare-metal worker nodes (both normal-worker and tuned-worker pools share this hardware profile; differences in their KubeletConfig are noted where relevant)

### Severity Levels

| Level | Meaning |
|-------|---------|
| **CRITICAL** | Misconfiguration causing or risking production incidents |
| **WARNING** | Sub-optimal setting; should be reviewed |
| **INFO** | Worth understanding; default is usually acceptable |
| **DEFAULT OK** | Leave at default unless you have a specific, measured reason |

### Configuration Layers

| Layer | Applied via | Requires reboot? | Scope |
|-------|-----------|-------------------|-------|
| **KubeletConfig** | `machineconfiguration.openshift.io/v1` CR | Yes (MCO rollout) | Kubelet process behavior |
| **PerformanceProfile** | `performance.openshift.io/v2` CR | Yes (MCO rollout) | CPU pinning, NUMA, hugepages, kernel args |
| **MachineConfig** | `machineconfiguration.openshift.io/v1` CR | Yes (MCO rollout) | Kernel boot params, sysctl, systemd units |
| **TuneD (NTO)** | `tuned.openshift.io/v1` CR | **No** — applied live | Sysctls, NIC hardware, CPU governor |

---

## Quick Reference Table

Every tunable parameter at a glance. Deep-dive sections follow for parameters marked with a section reference.

### KubeletConfig Parameters

| Parameter | OCP 4.16 Default | Category | Tune? | Section |
|-----------|-----------------|----------|-------|---------|
| `autoSizingReserved` | false | System Resources | Enable on VMs; manual sizing for high-density BM | §1 |
| `systemReserved.cpu` | 500m | System Resources | Manual only for high-density BM | §1 |
| `systemReserved.memory` | 1Gi | System Resources | Manual only for high-density BM | §1 |
| `systemReserved.ephemeral-storage` | 1Gi | System Resources | Rarely | §1 |
| `maxPods` | 250 | Pod Density | Yes, if pod density requires it | §2 |
| `podPidsLimit` | 4096 | Pod Density | **CRITICAL — verify not 1024** | §2 |
| `kubeAPIQPS` | 50 | Pod Density | Raise proportionally to maxPods | §2 |
| `kubeAPIBurst` | 100 | Pod Density | Raise proportionally to maxPods | §2 |
| `evictionHard.memory.available` | 100Mi | Eviction | Raise on large-memory BM nodes | §3 |
| `evictionSoft.memory.available` | *(not set)* | Eviction | Configure on BM nodes | §3 |
| `evictionSoftGracePeriod` | *(not set)* | Eviction | **Required** if using soft eviction | §3 |
| `evictionPressureTransitionPeriod` | 5m0s | Eviction | DEFAULT OK | §3 |
| `imageMinimumGCAge` | 2m0s | Image Lifecycle | DEFAULT OK | §4 |
| `imageGCHighThresholdPercent` | 85 | Image Lifecycle | Lower on disk-constrained nodes | §4 |
| `imageGCLowThresholdPercent` | 80 | Image Lifecycle | Adjust with High threshold | §4 |
| `nodeStatusMaxImages` | 50 | Image Lifecycle | Raise with caution on image-heavy nodes | §4 |
| `topologyManagerPolicy` | none | CPU & NUMA | Change for NUMA-aware workloads (requires `cpuManagerPolicy: static` to be useful) | §5 |
| `topologyManagerScope` | container | CPU & NUMA | DEFAULT OK | §5 |
| `cpuManagerPolicy` | none | CPU & NUMA | `static` for exclusive core pinning | §5 |
| `memoryManagerPolicy` | None | CPU & NUMA | DEFAULT OK | §5 |
| `allowedUnsafeSysctls` | *(not set)* | Networking | Add sysctls pods need to set per-namespace | §6 |
| `registryPullQPS` | 5 | Registry | Raise for burst pod creation | §7 |
| `registryBurst` | 10 | Registry | Raise for burst pod creation | §7 |
| `serializeImagePulls` | false | Registry | DEFAULT OK (already parallel) | §7 |
| `runtimeRequestTimeout` | 2m0s | Timeouts | DEFAULT OK (does not apply to image pulls) | §8 |
| `streamingConnectionIdleTimeout` | 4h0m0s | Timeouts | DEFAULT OK | §8 |
| `shutdownGracePeriod` | 0s | Shutdown | Enable for graceful drain | §8 |
| `shutdownGracePeriodCriticalPods` | 0s | Shutdown | Enable with shutdownGracePeriod | §8 |
| `containerLogMaxSize` | 50Mi | Logging | DEFAULT OK | §8 |
| `containerLogMaxFiles` | 5 | Logging | DEFAULT OK | §8 |
| `logging.verbosity` | 2 | Logging | DEFAULT OK | §8 |
| `authentication.webhook.cacheTTL` | 2m0s | Auth Caching | DEFAULT OK — do not set to 0 | §8 |
| `authorization.webhook.cacheAuthorizedTTL` | 5m0s | Auth Caching | DEFAULT OK — do not set to 0 | §8 |

### PerformanceProfile Parameters

| Parameter | Default | Category | Tune? | Section |
|-----------|---------|----------|-------|---------|
| `spec.cpu.reserved` | *(not set)* | CPU Pinning | Yes, for latency-sensitive BM | §5 |
| `spec.cpu.isolated` | *(not set)* | CPU Pinning | Yes, for latency-sensitive BM | §5 |
| `spec.hugepages` | *(not set)* | Memory | For DPDK/SR-IOV workloads | §9 |
| `spec.realTimeKernel` | false | Kernel | For ultra-low-latency only | §9 |
| `spec.numa.topologyPolicy` | *(not set)* | NUMA | Sets kubelet topologyManager | §5 |
| `spec.globallyDisableIrqLoadBalancing` | false | IRQ | For isolated CPU workloads | §9 |

### TuneD / NTO Parameters

TuneD (via the Node Tuning Operator) applies settings live without reboots. These are the parameters currently managed through TuneD CRs in this environment:

**Network sysctls (`[sysctl]` section):**

| Parameter | Value | Severity | Applies to |
|-----------|-------|----------|-----------|
| `net.ipv4.tcp_rmem` | 4096 3145728 6291456 | **CRITICAL** | enic only — fixes RHEL 9.4 TCP window regression (KCS 7127975) causing multi-hour image pulls |
| `net.core.netdev_budget` | 600 | INFO | BM only — increases NAPI polling budget to reduce softnet squeezes |
| `net.core.netdev_max_backlog` | 5000 | INFO | BM only — increases per-CPU backlog queue for high packet rates |
| `net.core.rmem_max` | 16777216 (16MB) | INFO | BM — ceiling for receive socket buffer size (memory allocated on demand, not pre-allocated) |
| `net.core.wmem_max` | 16777216 (16MB) | INFO | BM — ceiling for send socket buffer size |
| `net.core.somaxconn` | 10240 | INFO | Infra only — listen backlog for host-network routers. Ordinary pods in their own network namespace get the kernel default (4096) regardless of this setting. |
| `net.ipv4.tcp_max_syn_backlog` | 8192 | INFO | Infra only — SYN queue depth for high connection rates |
| `fs.file-max` | 2097152 | INFO | Infra only — maximum open file descriptors system-wide |
| `net.ipv4.ip_local_port_range` | 1024 65535 | WARNING | Infra only — widens ephemeral port range. Starting at 1024 risks conflicts with services that bind to ports in the 1024–32767 range. Consider `10240 65535` or `32768 65535` instead. |
| `vm.max_map_count` | 262144 | INFO | Infra only — for Elasticsearch/Java workloads |

**NIC hardware settings (`[net]` section):**

| Parameter | Value | Status | Applies to |
|-----------|-------|--------|-----------|
| Ring buffers | rx 4096 tx 4096 | Ready | vmxnet3, i40e, bnxt_en — increases hardware RX/TX ring depth |
| Channels | combined 16 | Partial | i40e, bnxt_en — multi-queue for RSS; requires NUMA verification |
| Coalesce | adaptive-rx/tx or fixed 125µs | Ready | i40e, bnxt_en — interrupt moderation tuning |
| Features | ntuple on, rx-gro-hw on | Ready | i40e, bnxt_en (NOT enic) — enables aRFS and hardware GRO |
| IRQ affinity | *(irqbalance, no pinning)* | Deferred | Would require PerformanceProfile for proper implementation |

**Transparent HugePages (`[vm]` section):**

| Node role | THP value | Rationale |
|-----------|-----------|-----------|
| Control plane | `always` (keep default) | API server and etcd benefit from reduced TLB misses |
| Infra | `always` (keep default) | HAProxy/router pods benefit for connection buffers |
| Workers | `never` | Compaction latency causes unpredictable stalls for application workloads |

**CPU C-states:** Under investigation. Restricting C-states to C1 eliminates ~100µs wake-up latency for interrupt handling but increases power/heat. Can be restricted at runtime via TuneD's `[cpu] force_latency=1` (no reboot needed) or permanently via kernel boot arguments through MachineConfig or PerformanceProfile. See §9.

**IRQ affinity:** Deferred. `irqbalance` provides adequate interrupt distribution for current workloads. Revisit if per-CPU `softnet_drops` are concentrated or per-queue RX counts are uneven after deploying primary network fixes. See §5 for NUMA/IRQ interaction details.

---

## §1 — System Resource Reservation

**KubeletConfig fields:** `autoSizingReserved`, `systemReserved.cpu`, `systemReserved.memory`, `systemReserved.ephemeral-storage`

### What it does

`systemReserved` carves out CPU, memory, and ephemeral storage from the node's allocatable pool. The scheduler cannot place pods into reserved resources. This protects kubelet, CRI-O, systemd, kernel threads, and other system processes from pod resource pressure.

`autoSizingReserved` (OCP-specific, available since 4.8) calculates these values automatically using a formula based on node capacity. Starting with OCP 4.21, it is enabled by default for new installations.

### The formula (OCP 4.16)

**CPU** (per KCS 5843241):
- 6% of first core + 1% of second + 0.5% of next 2 + 0.25% of remaining
- **Minimum enforced: 500m** (regardless of calculation). On a 56-core node the formula yields 210m, but the kubelet applies the 500m floor.

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
| **Master VM** | Enable `autoSizingReserved: true`. The auto-calculated values are appropriate for control-plane workloads (etcd, API server, controllers). |
| **Infra VM** | Enable `autoSizingReserved: true`. Infra nodes run routers and monitoring, which have predictable resource profiles. |
| **Worker BM (≤250 pods)** | Enable `autoSizingReserved: true`. For standard density, auto-sizing is sufficient. |
| **Worker BM (250–500 pods)** | **Manual tuning required.** Auto-sizing reserves only 500m CPU (the enforced minimum), which is inadequate for high pod counts. Case 03703812 showed kubelet consuming 6+ CPU cores under GC pressure with maxPods=500. Recommended: `cpu: 4000m, memory: 10Gi, ephemeral-storage: 1Gi` (per Case 03562048 engineering recommendation). |

### WARNING — auto-sizing CPU is insufficient for 500-pod nodes

KCS 5843241 notes that auto-sizing was designed for the default pod density (250 pods). Its internal notes state: *"For large nodes → 500 pods per node — automatic reservation is not allocating enough CPU."* When `maxPods` is raised, kubelet's internal GC, status reporting, and pod lifecycle management consume proportionally more CPU.

**This affects both the normal-worker and tuned-worker pools.** The normal-worker pool uses `autoSizingReserved: true` with `maxPods: 500`, meaning it gets only 500m CPU reserved — the same value as a 4-core VM running 250 pods. It should either switch to manual sizing or have its `maxPods` reduced.

### When to go manual vs auto

| Situation | Use auto-sizing | Use manual |
|-----------|----------------|------------|
| Default pod density (≤250) | ✓ | |
| High pod density (250-500) | | ✓ — increase CPU to 4000m+ |
| Latency-sensitive workloads | | ✓ — with PerformanceProfile |
| Large bare-metal nodes (56+ cores) at high density | | ✓ — auto CPU is too low |
| Standard VM nodes | ✓ | |

### Customer finding — tuned-worker systemReserved

The tuned-worker has `systemReserved: cpu: 4000m, memory: 500Mi`. Red Hat engineering recommended `cpu: 4000m, memory: 10Gi` (Case 03562048). The CPU value was adopted; the memory value is 20x below the recommendation and 45x below what auto-sizing would calculate. See Appendix A for the full gap analysis.

---

## §2 — Pod Density & Scheduling

**KubeletConfig fields:** `maxPods`, `podPidsLimit`, `kubeAPIQPS`, `kubeAPIBurst`

### maxPods

**Default:** 250
**What it does:** Maximum number of pods the kubelet will run on this node.

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

`maxPods` must not exceed the IP address space available per node. Changing `hostPrefix` after installation is not supported without cluster reinstall.

**Per-archetype:**

| Archetype | Recommendation |
|-----------|---------------|
| Master VM | 250 (default) — masters run control-plane pods, not workloads |
| Infra VM | 100-250 — infra runs routers/monitoring, fewer but heavier pods |
| Worker BM | 250-500 — if raising above 250, also raise kubeAPIQPS/Burst and switch to manual systemReserved |

### podPidsLimit

**Default:** 4096 (since OCP 4.11; was 1024 before 4.11)
**What it does:** Maximum number of PIDs (processes/threads) a single pod can spawn. Enforced via cgroup `pids.max`.

**When to raise:** Almost never. 4096 is generous for most workloads.
**When to lower:** Avoid. See below.

| Value | Context |
|-------|---------|
| 1024 | Pre-OCP-4.11 default. Insufficient for Go runtime thread accumulation, Java thread pools, Node.js worker threads |
| 4096 | Current OCP 4.11+ default. Appropriate for most workloads |
| 8192+ | Only for workloads with extreme thread counts (HPC, large JVMs) |

**CRITICAL — Customer finding:** The infra-kubeletconfig and tuned-worker-kubeletconfig have `podPidsLimit: 1024`. This was deliberately set during the July 2023 CRI-O panic crisis (Case 03548427) as an emergency measure against 10,000+ zombie processes. The internal update on July 5 confirmed: *"CU tried the crio wipe and reduced the pid limit to 1024 and still faced the issue with the nodes."* The setting did not fix the problem — the actual fix was the CRI-O bugfix in OCP 4.12.30. The value was never reverted.

In June 2026, this value directly caused a Multus thread exhaustion outage (Case 04472910, OCP 4.16). The Go runtime accumulated threads during OVS/OVN stalls (60→75→82→1024) and hit `pids.max=1024`, causing cluster-wide pod networking failure. Root cause: Go runtime never releases idle OS threads (`golang/go#14592`).

Note that `podPidsLimit` set explicitly in a KubeletConfig CR persists through OCP upgrades — the new default of 4096 only applies to clusters that never set the value explicitly. This is not an upgrade bug; it is how KubeletConfig CRs work. The lesson is that **emergency configuration changes need a revert ticket** once the root cause is resolved.

### kubeAPIQPS / kubeAPIBurst

**Defaults:** QPS=50, Burst=100
**What they do:** Client-side rate limit for the kubelet's requests to the API server. QPS is the sustained rate; Burst is the peak. These prevent a single kubelet from flooding the API server.

**When to raise:** When `maxPods` > 250 or when nodes have many watches/mounts.

| maxPods | Recommended QPS | Recommended Burst |
|---------|----------------|-------------------|
| ≤250 | 50 (default) | 100 (default) |
| 250-500 | 100 | 200 |
| 500+ | 150-200 | 300-400 |

**How to detect client-side throttling:** Look for `"Waited for ... due to client-side throttling"` messages in kubelet logs, or monitor `rest_client_rate_limiter_duration_seconds` in Prometheus. Do **not** rely on HTTP 429 responses — those indicate API server-side throttling, and raising the kubelet's client-side QPS would make that problem *worse*, not better.

**Customer finding — normal-worker pool:** The normal-worker pool runs `maxPods: 500` with the default `kubeAPIQPS: 50` and `kubeAPIBurst: 100`. Per the table above, this should be raised to QPS=100, Burst=200.

---

## §3 — Eviction Management

**KubeletConfig fields:** `evictionHard`, `evictionSoft`, `evictionSoftGracePeriod`, `evictionPressureTransitionPeriod`

### How eviction works

Kubernetes provides two layers of memory protection:

1. **Hard eviction** — When free memory drops below the threshold, kubelet immediately kills the lowest-priority pods (BestEffort first, then Burstable, then Guaranteed).
2. **Soft eviction** — When free memory drops below the threshold for longer than the grace period, kubelet gracefully terminates pods (respects terminationGracePeriodSeconds).

**Critical concept:** The hard eviction threshold is subtracted from allocatable:

```
Allocatable = Capacity - systemReserved - kubeReserved - evictionHard
```

This means the scheduler already accounts for the hard threshold when placing pods.

### Default vs tuned eviction

| Signal | OCP Default (Hard) | OCP Default (Soft) | Recommended for Worker BM (756GB) |
|--------|-------------------|-------------------|--------------------------|
| `memory.available` | 100Mi | *(not set)* | Hard: 4-8Gi, Soft: 10-16Gi |
| `nodefs.available` | 10% | *(not set)* | Hard: 10%, Soft: 15-20% |
| `nodefs.inodesFree` | 5% | *(not set)* | Hard: 5%, Soft: 10% |
| `imagefs.available` | 15% | *(not set)* | Hard: 10-15%, Soft: 20-25% |

### When to configure soft eviction

Soft eviction is disabled by default. Enable it when:
- Nodes have large amounts of RAM (128GB+) where the default 100Mi hard threshold provides almost no warning
- You want graceful pod termination before hard eviction
- You need a larger buffer for system processes

**Important:** The kubelet **rejects** a configuration that specifies `evictionSoft` thresholds without corresponding `evictionSoftGracePeriod` entries. Both must be set together. The grace period defines how long the threshold must be breached before eviction begins.

### Memory eviction and kernel buffers

TuneD network tuning (e.g., `net.core.rmem_max=16777216`) sets a ceiling for TCP socket buffer sizes. The actual memory is allocated on demand as connections use it, not pre-allocated.

On cgroup v2 (the default for OCP 4.16 new installs), kernel socket buffer memory charged to the `memory.current` of the pod's cgroup is visible to the kubelet's eviction accounting. On cgroup v1 (which clusters upgraded from OCP 4.12 may still use), this memory is **not** tracked by pod cgroups and directly reduces "available" memory from kubelet's perspective. **Verify which cgroup version your cluster uses** (`stat -fc %T /sys/fs/cgroup/` — `cgroup2fs` for v2, `tmpfs` for v1).

On nodes with tuned TCP buffers and many network-heavy pods, set memory eviction thresholds higher to provide a safety margin.

### Per-archetype guidance

| Archetype | Hard memory | Soft memory | Soft grace |
|-----------|------------|-------------|------------|
| Master VM | 100Mi (default) | Not needed | — |
| Infra VM | 100Mi (default) | Not needed | — |
| Worker BM (756GB) | 4-8Gi | 10-16Gi | 1m30s-5m |

### evictionPressureTransitionPeriod

**Default:** 5m0s
**What it does:** After eviction pressure is relieved, kubelet waits this long before removing the condition taint. Prevents rapid oscillation between pressure/no-pressure states.

**Recommendation:** Keep at default (5m0s).

**Note on the customer's tuned-worker:** The `evictionPressureTransitionPeriod: 0s` in the current config is a **config dump artifact** — it was included when the running kubelet config was extracted and pasted into the KubeletConfig CR. The kubelet replaces a zero duration with its compiled default (5m0s), so this value is currently harmless. However, it should be removed for clarity — explicitly zeroed fields add noise and their treatment could change between Kubernetes versions. The same applies to all 14 zero-value fields in the tuned-worker config (see Appendix A).

---

## §4 — Image Lifecycle

**KubeletConfig fields:** `imageMinimumGCAge`, `imageGCHighThresholdPercent`, `imageGCLowThresholdPercent`, `nodeStatusMaxImages`

### Image garbage collection

The kubelet periodically checks disk usage on the image filesystem. When usage exceeds `imageGCHighThresholdPercent`, it starts removing unused images (oldest first) until usage drops to `imageGCLowThresholdPercent`.

| Parameter | Default | Effect of changing |
|-----------|---------|-------------------|
| `imageGCHighThresholdPercent` | 85 | Lower = GC starts sooner (more aggressive) |
| `imageGCLowThresholdPercent` | 80 | Lower = GC frees more space (more aggressive) |
| `imageMinimumGCAge` | 2m0s | Higher = images kept longer before eligible for GC |

**When to tune:**
- **Disk-constrained nodes:** Lower High/Low thresholds (e.g., 75/50) for more aggressive cleanup
- **Air-gapped / slow-registry environments:** Raise `imageMinimumGCAge` to avoid re-pulling images that take a long time to pull
- **Enic NIC driver nodes:** Aggressive image GC combined with the TCP window regression (KCS 7127975) can cause hours-long re-pulls. Deploy the `tcp_rmem` TuneD fix before enabling aggressive image GC on enic nodes.

### nodeStatusMaxImages

**Default:** 50
**What it does:** Maximum number of images reported in the node status object. Does not affect actual image storage.

**When to raise:** Nodes running many different container images (common on large BM nodes with 500 pods). Raise to 250-500 for better observability.

**Performance note:** Higher values make every Node API object larger. Every component watching Node objects (scheduler, controllers, monitoring) receives the larger payload. On clusters with many nodes, this can increase API server and etcd load. Measure before setting above 500.

---

## §5 — CPU Topology, NUMA & Pinning

**KubeletConfig fields:** `topologyManagerPolicy`, `topologyManagerScope`, `cpuManagerPolicy`
**PerformanceProfile fields:** `spec.cpu.reserved`, `spec.cpu.isolated`, `spec.numa.topologyPolicy`

### Overview

Modern multi-socket servers have Non-Uniform Memory Access (NUMA) architecture. Memory access latency depends on which CPU socket accesses which memory bank. For latency-sensitive workloads, ensuring pods use CPUs and memory from the same NUMA node is critical.

On a typical 2-socket bare-metal node (e.g., 56 cores):
```
Socket 0: CPUs 0-27, Memory Bank 0
Socket 1: CPUs 28-55, Memory Bank 1
```

### topologyManagerPolicy

| Policy | Behavior | Use case |
|--------|----------|----------|
| `none` (default) | No NUMA awareness. Pods get CPUs from any socket. | General-purpose workloads |
| `best-effort` | Tries to align CPU/memory to same NUMA node but doesn't fail if it can't | Mixed workloads with some NUMA-sensitive pods |
| `restricted` | Requires NUMA alignment for pods with Guaranteed QoS; rejects pod if alignment impossible | Latency-sensitive workloads |
| `single-numa-node` | Requires all resources from a single NUMA node | Ultra-low-latency, DPDK |

**Important:** `topologyManagerPolicy` only affects pods with Guaranteed QoS (requests == limits) when `cpuManagerPolicy: static` is also set. With `cpuManagerPolicy: none` (the default), the topology manager has no CPU topology hints to work with for ordinary pods, and `best-effort` or `restricted` has no practical effect.

**Customer finding — tuned-worker:** The tuned-worker sets `topologyManagerPolicy: best-effort` but leaves `cpuManagerPolicy: none`. This combination has no meaningful effect on pod placement. To make it useful, either set `cpuManagerPolicy: static` or deploy a PerformanceProfile.

**Per-archetype:**

| Archetype | Recommendation |
|-----------|---------------|
| Master VM | `none` — VMs present a flat topology to the guest |
| Infra VM | `none` — same reason |
| Worker BM | `best-effort` or `restricted` only if also setting `cpuManagerPolicy: static`. Otherwise leave at `none`. |

### cpuManagerPolicy

| Policy | Behavior | Use case |
|--------|----------|----------|
| `none` (default) | CFS scheduler distributes CPU time. Pods share cores. | General workloads |
| `static` | Guaranteed QoS pods with integer CPU requests get exclusive cores. Other pods share remaining cores. | Latency-sensitive, deterministic performance |

**When to use `static`:** When pods need guaranteed, exclusive CPU cores without preemption. Setting `cpuManagerPolicy: static` via KubeletConfig gives pods exclusive cores, but you cannot control **which** cores are reserved for system processes — the kubelet picks them. To control which cores go to system vs workloads, use a PerformanceProfile.

### CPU pinning — should you pin system CPUs?

CPU pinning for system processes is configured via **PerformanceProfile**, not directly in KubeletConfig. The PerformanceProfile divides CPUs into:

- **reserved** — System processes (kubelet, CRI-O, systemd, kernel threads, IRQ handlers)
- **isolated** — Workload pods with Guaranteed QoS and integer CPU requests

**Example for a 56-core, 2-socket node with hyperthreading:**

Reserved CPUs must include **whole physical cores** (both hyperthread siblings). Use `lscpu -p` on the node to identify sibling pairs. On a typical dual-socket 56-core system with HT, there are 112 logical CPUs. The example below assumes cores 0-3 and 28-31 map to physical cores with siblings 56-59 and 84-87:

```yaml
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: worker-bm-tuned
spec:
  cpu:
    reserved: "0-3,28-31,56-59,84-87"   # 8 physical cores (16 logical) across both sockets
    isolated: "4-27,32-55,60-83,88-111"  # remaining cores for workloads
  numa:
    topologyPolicy: "restricted"
  nodeSelector:
    node-role.kubernetes.io/worker-tuned: ""
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker-tuned: ""
```

**How many cores to reserve?**

| Factor | Guidance |
|--------|----------|
| Base kubelet/CRI-O | 4-6 cores (Case 03703812 showed kubelet consuming 6+ cores under GC pressure) |
| IRQ handling | 1-2 cores per high-speed NIC |
| systemd + kernel threads | 1-2 cores |
| **Total recommended** | **6-10 physical cores for high-density + network-heavy BM** |

**Which cores to reserve?**
- Reserve cores from **both NUMA nodes** (e.g., 0-3 from socket 0, 28-31 from socket 1)
- **Include hyperthread siblings** — reserving only one thread of a physical core leaves the sibling available for workloads, which defeats isolation
- Core 0 always handles boot interrupts — always include it in reserved
- If the NIC is attached to a specific NUMA node, include extra reserved cores from that node for DMA locality (see below)
- Verify topology on the node: `oc debug node/<node> -- chroot /host lscpu -p`
- Check NIC NUMA affinity: `oc debug node/<node> -- chroot /host cat /sys/class/net/<iface>/device/numa_node`

**NUMA, RSS, aRFS, and IRQ affinity — how they interact:**

Several kernel mechanisms work together for packet delivery:

- **RSS (Receive Side Scaling):** The NIC distributes incoming packets across multiple RX queues using a header hash. Each queue is assigned to a CPU via its IRQ. RSS does not know which CPU runs the consuming thread.
- **RFS (Receive Flow Steering):** Software-level steering in the softirq path. After RSS delivers a packet to an RX queue, RFS checks which CPU last accessed this flow's socket and steers the packet there.
- **aRFS (Accelerated RFS):** Hardware-assisted RFS. The NIC itself steers packets to the CPU running the consuming thread. Requires `ntuple` feature support.
- **DMA locality:** The NIC's DMA ring buffers are allocated in the memory of the NUMA node where the NIC's PCIe root complex is attached. A CPU on the same NUMA node accesses local memory (~80ns); a cross-NUMA access adds ~70ns latency.

When `globallyDisableIrqLoadBalancing: true` is set via PerformanceProfile, hardware interrupts are pinned to reserved CPUs only. RSS queues deliver to reserved CPUs, and RFS/aRFS can still steer packets at the softirq layer. Reserving cores from the NIC's NUMA node ensures the initial hardware interrupt processing accesses DMA buffers with local memory latency, reducing the window for `rx_no_bufs` drops under high packet rates.

**The "should we pin cores 0-5 to system?" question:**

Pinning 6 cores from one socket only (e.g., 0-5) puts all reserved cores on one NUMA node. If the NIC is on the other socket, IRQ handlers incur cross-NUMA DMA latency. Better: split across both sockets — e.g., `0-2,28-30` (3 physical cores from each socket, plus their HT siblings).

### PerformanceProfile interactions with existing KubeletConfig

**Warning:** A PerformanceProfile generates its own KubeletConfig, MachineConfig, and TuneD resources behind the scenes. If the target MachineConfigPool already has a KubeletConfig CR, the two can conflict. Specifically:
- The PerformanceProfile's generated KubeletConfig sets `cpuManagerPolicy: static` and `topologyManagerPolicy` based on `spec.numa.topologyPolicy`.
- Its `reserved` CPUs override any manual `systemReserved.cpu` setting.
- Additional kubelet settings must be placed in the `kubeletconfig.experimental` annotation on the PerformanceProfile, not in a separate KubeletConfig CR.

### When to use PerformanceProfile vs plain KubeletConfig

| Need | KubeletConfig alone | PerformanceProfile |
|------|--------------------|--------------------|
| `topologyManagerPolicy: best-effort` | ✓ (but needs `cpuManagerPolicy: static` to be useful) | ✓ |
| `cpuManagerPolicy: static` (kubelet picks cores) | ✓ | ✓ (sets automatically) |
| Control **which** cores are reserved vs isolated | ✗ | ✓ |
| IRQ affinity control | ✗ | ✓ |
| HugePages | ✗ | ✓ |
| Kernel RT patches | ✗ | ✓ |
| C-state restriction (boot args) | ✗ | ✓ |

### Trade-offs of CPU pinning

| Benefit | Cost |
|---------|------|
| Predictable latency for pinned pods | Reduced core availability for non-pinned pods |
| No CPU context switching for isolated cores | More complex capacity planning |
| Better cache locality | Reserved cores may be underutilized |
| Required for DPDK/SR-IOV | PerformanceProfile is a heavier operational change, can conflict with existing KubeletConfig |

### Verification commands

All topology commands must be run **on the node**, not on the workstation:

```bash
# Check NUMA topology on a node
oc debug node/<node> -- chroot /host lscpu | grep -i numa

# Check CPU-to-NUMA mapping with HT siblings
oc debug node/<node> -- chroot /host lscpu -p | head -20

# Check NIC NUMA affinity
oc debug node/<node> -- chroot /host cat /sys/class/net/ens192/device/numa_node

# Check current CPU manager policy
oc get kubeletconfig -o yaml | grep cpuManagerPolicy

# Check if PerformanceProfile is active
oc get performanceprofile
```

---

## §6 — Pod-Level Sysctl Access

**KubeletConfig field:** `allowedUnsafeSysctls`

### What it does

Kubernetes classifies sysctls as "safe" (namespaced, isolated per pod) or "unsafe" (potentially affecting other pods or the host). By default, pods can only set safe sysctls. `allowedUnsafeSysctls` whitelists specific sysctls that pods may set in their `securityContext.sysctls`.

**Key distinction:** Several network sysctls including `net.core.somaxconn`, `net.ipv4.tcp_max_syn_backlog`, and `net.ipv4.ip_local_port_range` are set **per network namespace**. Each pod gets its own network namespace with kernel defaults (e.g., `somaxconn=4096` on RHEL 9). Setting these via TuneD at the host level **only affects host-network pods** (`hostNetwork: true`) and system processes — ordinary pods in their own namespace are unaffected.

This means:
- **TuneD's `somaxconn=10240` on infra nodes** benefits the OpenShift router (which uses `hostNetwork: true`) but does nothing for regular application pods.
- **`allowedUnsafeSysctls: [net.core.somaxconn]` in KubeletConfig** is needed if non-host-network pods need a somaxconn value different from the kernel default. The two settings serve different purposes and are **not redundant** — removing `allowedUnsafeSysctls` because "TuneD already covers it" would be incorrect.

### Finding which pods actually use allowedUnsafeSysctls

The `allowedUnsafeSysctls` setting only **permits** pods to set the sysctl — it doesn't apply it. If no pod spec includes the sysctl in its `securityContext.sysctls`, the setting has no effect.

To find pods and workloads that actually use it:

```bash
oc get pods,deploy,sts,ds -A -o json | jq -r '
  .items[] |
  (.spec.template.spec // .spec) as $s |
  select($s.securityContext.sysctls) |
  "\(.kind) \(.metadata.namespace)/\(.metadata.name): \([$s.securityContext.sysctls[].name] | join(","))"
'
```

If nothing is returned, the `allowedUnsafeSysctls` setting is a no-op and may have been added proactively or recommended during a consulting engagement without a specific workload needing it. It is harmless to leave in place.

### Per-archetype

| Archetype | Recommendation |
|-----------|---------------|
| Master | Not needed (masters don't run user workloads) |
| Infra | Add if non-host-network pods need somaxconn override |
| Worker (all) | Add sysctls that workload pods require in their securityContext |

### Safe vs unsafe sysctls

**Safe sysctls** (namespaced, always allowed without `allowedUnsafeSysctls`):
- `kernel.shm_rmid_forced`
- `net.ipv4.ip_local_port_range`
- `net.ipv4.tcp_syncookies`
- `net.ipv4.ping_group_range`
- `net.ipv4.ip_unprivileged_port_start`

**Unsafe sysctls** (require explicit allowlisting in the KubeletConfig):
- `net.core.somaxconn`
- `net.ipv4.tcp_max_syn_backlog`
- Any `net.*` sysctl not in the safe list
- Any `kernel.*` sysctl not in the safe list

---

## §7 — Registry & Image Pull

**KubeletConfig fields:** `registryPullQPS`, `registryBurst`, `serializeImagePulls`

### registryPullQPS / registryBurst

**Defaults:** QPS=5, Burst=10
**What they do:** Rate limit for image pull requests to container registries.

**When to raise:** When many pods start simultaneously (e.g., after node drain/reboot with 300-400 pods). Symptoms: "pull QPS exceeded" events, slow pod startup.

| Scenario | Recommended QPS | Recommended Burst |
|----------|----------------|-------------------|
| Standard (≤250 pods) | 5 (default) | 10 (default) |
| High density (250-500 pods) | 20-50 | 40-100 |
| Burst recovery (post-drain) | 50 | 100 |

**Case 04046963:** Customer configured `registryPullQPS: 50, registryBurst: 100` to resolve "pull QPS exceeded" errors during burst pod creation after node drains.

### serializeImagePulls

**Default:** false (parallel pulls enabled)
**What it does:** When true, images are pulled one at a time. When false, multiple pulls happen concurrently.

**Recommendation:** Keep at false (default). Parallel pulls are faster, especially in air-gapped environments with local mirrors.

---

## §8 — Timeouts, Shutdown & Operational Parameters

### runtimeRequestTimeout

**Default:** 2m0s
**What it does:** Timeout for CRI-O operations such as container create, start, and stop.

**Note:** Image pulls are handled separately by CRI-O and are generally not subject to this timeout. Slow image pulls in air-gapped environments are better addressed by increasing `registryPullQPS/Burst` or fixing the underlying network issue (e.g., the enic `tcp_rmem` regression).

### streamingConnectionIdleTimeout

**Default:** 4h0m0s
**What it does:** How long `oc exec`, `oc attach`, and port-forward sessions stay open when idle.

**Recommendation:** Keep at default.

### shutdownGracePeriod / shutdownGracePeriodCriticalPods

**Defaults:** Both 0s (graceful shutdown disabled)
**What they do:** When the node receives a shutdown signal, kubelet gracefully terminates pods instead of letting the OS kill them.

| Parameter | Recommended |
|-----------|-------------|
| `shutdownGracePeriod` | 60s-120s — total time for all pod termination |
| `shutdownGracePeriodCriticalPods` | 15s-30s — portion reserved for critical pods (from the end of the total period) |

**When to enable:** If nodes are shut down/rebooted outside of `oc drain` (e.g., hardware maintenance, power events). `oc drain` already handles graceful termination; this setting protects against ungraceful shutdown.

### Authentication/Authorization webhook cache

**Defaults:** `authentication.webhook.cacheTTL: 2m0s`, `authorization.webhook.cacheAuthorizedTTL: 5m0s`, `authorization.webhook.cacheUnauthorizedTTL: 30s`

These caches apply to requests **to the kubelet** (e.g., from the metrics server, log collectors, exec/attach). They are not related to `kubeAPIQPS` or pod count.

**Recommendation:** Keep at defaults. The customer's tuned-worker has these set to 0s as a config dump artifact. The kubelet replaces zero durations with compiled defaults, so the current behavior is correct. Remove the explicit 0s values for clarity.

### Logging

**Default:** `logging.verbosity: 2`
**Recommendation:** Keep at 2 for production. Raise to 4-5 temporarily for debugging. Level 0 may hide useful diagnostics.

---

## §9 — Advanced: PerformanceProfile & MachineConfig

These items go beyond KubeletConfig and require node reboots (MCO rollout).

### HugePages

Configure via PerformanceProfile if workloads require them (DPDK, databases, JVMs with large heaps):

```yaml
spec:
  hugepages:
    defaultHugepagesSize: "1Gi"
    pages:
      - count: 16
        size: "1Gi"
        node: 0
```

**Per-archetype:** Only configure on worker BM nodes running workloads that explicitly request hugepages. Never on masters or infra.

### Real-Time Kernel

```yaml
spec:
  realTimeKernel:
    enabled: true
```

**When to use:** Only for ultra-low-latency workloads (telco RAN, industrial control). The RT kernel adds overhead for general-purpose workloads. Not recommended for this customer's current workload profile.

### C-States (CPU idle)

C-states can be restricted in two ways:

1. **Runtime (no reboot):** TuneD's `[cpu]` section with `force_latency=1` limits C-states to C1 while the profile is active. This is the lightest approach.
2. **Boot-time (reboot required):** Kernel arguments via PerformanceProfile or MachineConfig:

```yaml
spec:
  additionalKernelArgs:
    - "intel_idle.max_cstate=1"
    - "processor.max_cstate=1"
```

**Trade-off:** Restricting C-states to C1 eliminates ~100µs wake-up latency for interrupt handling (improves NIC packet processing) but increases power consumption and heat. Only do this if `rx_no_bufs` drops persist after deploying ring buffer and backlog TuneD fixes.

### IRQ Affinity

IRQ affinity pinning is configured via PerformanceProfile. Setting `globallyDisableIrqLoadBalancing: true` ensures hardware interrupts only go to reserved CPUs, keeping isolated CPUs free for workload pods.

**Note:** The `spec.net.devices` field in PerformanceProfile controls NIC queue counts when `userLevelNetworking: true` (for DPDK). It does not control IRQ affinity by itself. IRQ affinity for non-DPDK use is controlled by `globallyDisableIrqLoadBalancing` and the reserved CPU set.

---

## §10 — Parameters You Should NOT Touch

These parameters are managed by OpenShift or have no practical reason to change:

| Parameter | Default | Why leave it alone |
|-----------|---------|-------------------|
| `cgroupDriver` | systemd | Required by OpenShift; changing breaks CRI-O |
| `cgroupsPerQOS` | true | Required for QoS class enforcement |
| `protectKernelDefaults` | false (OCP default) | Set by MCO; changing may conflict with RHCOS kernel defaults |
| `failSwapOn` | true | Swap is not supported on RHCOS |
| `rotateCertificates` | true | Required for certificate rotation |
| `serverTLSBootstrap` | true | Required for kubelet TLS |
| `enableControllerAttachDetach` | true | Required for volume lifecycle |
| `tlsCipherSuites` | (hardened list) | Security requirement; do not weaken |
| `tlsMinVersion` | VersionTLS12 | Security requirement; do not lower |
| `enforceNodeAllocatable` | [pods] | Required for resource enforcement |
| `featureGates` | (managed by OCP) | Set by cluster version operator; manual changes are overwritten |
| `address` | 0.0.0.0 | Required for metrics/health endpoints |
| `port` | 10250 | Standard kubelet port |
| `clusterDNS` | (cluster-specific) | Set during installation |
| `clusterDomain` | cluster.local | Set during installation |
| `staticPodPath` | /etc/kubernetes/manifests | Required for control-plane static pods |
| `containerRuntimeEndpoint` | /var/run/crio/crio.sock | CRI-O socket path; do not change |
| `systemCgroups` | /system.slice | RHCOS systemd cgroup layout |
| `hairpinMode` | promiscuous-bridge | Required for service networking |
| `oomScoreAdj` | -999 | Protects kubelet from OOM killer |
| `maxOpenFiles` | 1000000 | Already set high; rarely needs change |
| `seccompDefault` | false | Enabling may break workloads without seccomp profiles |
| `memoryThrottlingFactor` | 0.9 | Kernel memory throttling ratio; default is appropriate |
| `cpuCFSQuota` | true | Required for CPU limit enforcement |
| `eventRecordQPS` / `eventBurst` | 50/100 | Event rate limiting; default is appropriate |
| `nodeLeaseDurationSeconds` | 40 | Node lease heartbeat; changing affects NotReady detection timing |

---

## Appendix A — Customer KubeletConfig Divergence Analysis

Baseline: live kubelet configz from a vanilla OCP 4.16.49 worker (no KubeletConfig CR applied).
Cluster: v1.29.14+f3d9123, RHCOS 416.94, kernel 5.14.0-427.91.1.el9_4.

### Case Archive Lore

Historical support cases that explain why specific KubeletConfig settings were chosen. Source: 83 cases from the customer archive, cross-referenced against each divergent setting.

**Case 03548427 — PLEG / CRI-O Panic (OCP 4.12, Jun–Sep 2023)**

The "master reference" case for this cluster's kubelet tuning. After upgrading from OCP 4.12.2 to 4.12.15, workers went NotReady with PLEG failures and CRI-O panics ("close of closed channel"). Cisco UCS bare-metal nodes (56 cores, 756GB RAM) with NetApp iSCSI.

Timeline of config changes during the crisis:
- **Jun 29**: KubeletConfig dump shows original state: `autoSizingReserved: true`, `maxPods: 500`, `nodeStatusMaxImages: 500`, `allowedUnsafeSysctls: [net.core.somaxconn]`
- **Jul 2** (PS consultant): *"Over 10,000 zombie processes. Attempting to restrict container PIDs to 1024 (default value in 4.10)."*
- **Jul 3**: *"Changed pids_limit to 1024 on all workers."*
- **Jul 5** (Internal): *"CU tried the crio wipe and reduced the pid limit to 1024 and still faced the issue"* — the PID limit did not fix the issue.
- **Jul 5**: Investigation split: (1) maxPods=500 with default kubeAPIBurst/QPS + hostPrefix /23, (2) CRI-O race condition (actual root cause).
- **Jul 6**: Changed kubeletconfig — decreased maxPods to 400, increased kubeAPIQPS to 100 and kubeAPIBurst to 200.
- **Jul 17**: Customer kept auto-sizing, split cluster into two pools (maxPods=250 and maxPods=500).

Root cause: CRI-O race condition (OCPBUGS-15868), fixed in OCP 4.12.30 (RHSA-2023:4671).

**Case 03562048 — Manual Node Sizing (OCP 4.12, Jul 2023)**

Red Hat engineering recommended: `systemReserved cpu: 4000m, memory: 10Gi`. Auto-sizing yielded CPU=210m (enforced as 500m), Memory=22Gi for the 756GB workers. Customer decided not to switch, but the CPU recommendation (4000m) was later adopted. The memory recommendation (10Gi) was not — current value is 500Mi.

Auto-sizing values confirmed from `/etc/node-sizing.env`:
- Masters (20 vCPU, 130GB): memory=9Gi, cpu=117m (enforced 500m), es=1Gi
- Infra VMs (12 vCPU, 42GB): memory=4Gi, cpu=100m (enforced 500m), es=1Gi
- Workers BM (56 CPU, 756GB): memory=22Gi, cpu=210m (enforced 500m), es=1Gi

**Case 03703812 — Kubelet GC Under High Load (OCP 4.12, Jan 2024)**

Workers with maxPods=500 and systemReserved at 4 CPU cores + 20GB RAM had load averages over 100. Kubelet consumed up to 6 CPU cores. pprof showed GC as the top consumer. Resolved by cleaning pods stuck in error state. Confirms systemReserved.cpu: 4000m is justified.

**Case 04046963 — Pod Startup Delay After Drain (OCP 4.12, Jan–Mar 2025)**

300-400 pods restarting simultaneously caused CRI-O timeouts. Confirmed systemReserved.memory was already at 500Mi. Configured registryPullQPS: 50, registryBurst: 100. Tried increasing to 8 cores CPU and 5Gi memory with no improvement (the issue was OVS-related, not resource starvation).

**Case 04472910 — Multus Thread Exhaustion (OCP 4.16, Jun 2026)**

Multus daemon hit pids.max=1024 due to Go runtime thread accumulation during OVS/OVN stalls. Red Hat recommended raising podPidsLimit to 4096 immediately.

### Per-Pool Divergence Tables

**master-kubeletconfig** — 1 divergence:

| Field | OCP Default | Customer Value | Origin | Notes |
|-------|-------------|----------------|--------|-------|
| `autoSizingReserved` | not set | true | Case 03548427 | Auto-calculates system reserves |

**infra-kubeletconfig** — 5 divergences:

| Field | OCP Default | Customer Value | Severity | Origin | Notes |
|-------|-------------|----------------|----------|--------|-------|
| `autoSizingReserved` | not set | true | INFO | Case 03548427 | Auto-calculates system reserves |
| `allowedUnsafeSysctls` | (none) | net.core.somaxconn | INFO | (no case lore) | Enables pod-level somaxconn override |
| `maxPods` | 250 | 100 | INFO | (no case lore) | Infra nodes run fewer, heavier pods |
| `nodeStatusMaxImages` | 50 | 250 | INFO | (no case lore) | Reports more images in node status |
| `podPidsLimit` | 4096 | 1024 | **CRITICAL** | Case 03548427 / 04472910 | Emergency measure (Jul 2023) that did not fix the CRI-O issue. Later caused Multus failure on OCP 4.16. |

**normal-worker-kubeletconfig** — 3 divergences:

| Field | OCP Default | Customer Value | Severity | Origin | Notes |
|-------|-------------|----------------|----------|--------|-------|
| `autoSizingReserved` | not set | true | **WARNING** | Case 03548427 | Auto-sizing reserves only 500m CPU for a 500-pod node. Manual sizing needed. |
| `allowedUnsafeSysctls` | (none) | net.core.somaxconn | INFO | (no case lore) | Enables pod-level somaxconn override |
| `maxPods` | 250 | 500 | **WARNING** | Case 03548427 | High-density with default kubeAPIQPS=50 — should be raised to 100 |

**tuned-worker-kubeletconfig** — 23 intentional divergences + 14 config dump artifacts:

| Field | OCP Default | Customer Value | Severity | Origin | Notes |
|-------|-------------|----------------|----------|--------|-------|
| `autoSizingReserved` | true (other roles) | not set | WARNING | Case 03562048 | Only role without auto-sizing; uses manual systemReserved instead |
| `systemReserved.cpu` | 500m | 4000m | INFO | Case 03562048 / 03703812 | Correctly adopted from engineering recommendation |
| `systemReserved.memory` | 1Gi | 500Mi | **CRITICAL** | Case 04046963 | Engineering recommended 10Gi. Current value is 20x below. |
| `systemReserved.ephemeral-storage` | 1Gi | not set (0) | WARNING | — | Lost when switching from auto-sizing to manual |
| `allowedUnsafeSysctls` | (none) | net.core.somaxconn | INFO | Case 03548427 | Enables pod-level somaxconn override |
| `maxPods` | 250 | 500 | INFO | Case 03548427 | High-density bare-metal |
| `nodeStatusMaxImages` | 50 | 500 | INFO | Case 03548427 | Large image cache on bare-metal |
| `podPidsLimit` | 4096 | 1024 | **CRITICAL** | Case 03548427 / 04472910 | Emergency measure that did not fix the CRI-O issue. Caused Multus failure on 4.16. |
| `kubeAPIQPS` | 50 | 100 | INFO | Case 03548427 | Correctly raised for 500-pod density |
| `kubeAPIBurst` | 100 | 200 | INFO | Case 03548427 | Correctly raised alongside QPS |
| `topologyManagerPolicy` | none | best-effort | WARNING | (no case lore) | No-op without cpuManagerPolicy: static |
| `imageMinimumGCAge` | 2m0s | 5m | INFO | (no case lore) | More lenient GC |
| `imageGCHighThresholdPercent` | 85 | 75 | INFO | (no case lore) | More aggressive disk management |
| `imageGCLowThresholdPercent` | 80 | 50 | INFO | (no case lore) | More aggressive cleanup |
| `evictionSoft.memory.available` | (not set) | 16000Mi | INFO | Case 03502380 | Soft eviction at 16GB |
| `evictionHard.memory.available` | 100Mi | 8000Mi | INFO | Case 03502380 | Hard eviction at 8GB |
| `evictionSoftGracePeriod (all)` | (not set) | 1m30s | INFO | — | 90-second grace before eviction |

**Zero-value config dump artifacts** (14 fields): The tuned-worker config contains `kind: KubeletConfiguration` and `apiVersion: kubelet.config.k8s.io/v1beta1` nested inside `.spec.kubeletConfig`, plus 14 fields set to `0s`/`0`. This indicates the config was extracted from a running kubelet rather than authored from scratch. The kubelet replaces zero durations with compiled defaults, so these values are currently harmless but should be removed for clarity.

| Field | OCP Default | Assessment |
|-------|-------------|-----------|
| `syncFrequency` | 1m0s | Remove — kubelet uses compiled default |
| `fileCheckFrequency` | 20s | Remove |
| `httpCheckFrequency` | 20s | Remove |
| `runtimeRequestTimeout` | 2m0s | Remove |
| `streamingConnectionIdleTimeout` | 4h0m0s | Remove |
| `nodeStatusReportFrequency` | 5m0s | Remove |
| `nodeStatusUpdateFrequency` | 10s | Remove |
| `evictionPressureTransitionPeriod` | 5m0s | Remove |
| `volumeStatsAggPeriod` | 1m0s | Remove |
| `authentication.webhook.cacheTTL` | 2m0s | Remove |
| `authorization.webhook.cacheAuthorizedTTL` | 5m0s | Remove |
| `authorization.webhook.cacheUnauthorizedTTL` | 30s | Remove |
| `logging.verbosity` | 2 | Remove |
| `logging.flushFrequency` | 5s | Remove |

### systemReserved Gap Analysis

Comparison for 56-core / 756GB bare-metal nodes (tuned-worker):

| Source | CPU | Memory | Eph-Storage |
|--------|-----|--------|-------------|
| Auto-sizing (formula output) | 210m | 22 Gi | 1Gi |
| Auto-sizing (enforced minimum) | 500m | 22 Gi | 1Gi |
| RH Engineering recommended (Case 03562048) | 4000m | 10 Gi | 1Gi |
| OCP static default (no auto-sizing) | 500m | 1 Gi | 1Gi |
| **Customer actual (tuned-worker)** | 4000m | **500 Mi** | **not set** |

- Customer vs auto-sizing: 500Mi / 22Gi = 2.2% — 45x under-reserved
- Customer vs RH recommendation: 500Mi / 10Gi = 4.9% — 20x under-reserved
- Customer vs OCP default: 500Mi / 1Gi = 48.8% — 2x under-reserved

KCS 5843241 warns: *"Changing default values (like the podPidsLimit or the maxPods) could require more CPU and/or memory for system resources, so the automatic reservation could be not enough."*

### Recommendations Summary

1. **CRITICAL — Raise `podPidsLimit` to 4096** on infra-kubeletconfig and tuned-worker-kubeletconfig. Requires MCO rolling reboot of each pool.
2. **CRITICAL — Raise `systemReserved.memory` to 10Gi** on tuned-worker-kubeletconfig. Add `ephemeral-storage: 1Gi`. Requires MCO rolling reboot.
3. **CRITICAL — Deploy enic `tcp_rmem` TuneD fix** on bare-metal nodes with Cisco enic NICs before any workload churn.
4. **WARNING — Fix normal-worker pool:** Either switch to manual `systemReserved` (cpu: 4000m, memory: 10Gi) or raise `kubeAPIQPS` to 100 and `kubeAPIBurst` to 200. Currently under-provisioned for 500-pod density.
5. **WARNING — Clean up tuned-worker config dump artifacts:** Remove 14 zero-value fields, embedded `kind`/`apiVersion`, and redundant logging/auth blocks.
6. **WARNING — Fix `topologyManagerPolicy`:** Either also set `cpuManagerPolicy: static` (to make `best-effort` effective) or remove the setting.
7. **INFO — Document the memory eviction budget** for 756GB nodes.

---

## Appendix B — Case Archive Summary

| Case | Date | OCP | Topic | Settings Affected |
|------|------|-----|-------|-------------------|
| 03502380 | May 2023 | 4.8 | Eviction best practices | evictionSoft, evictionHard, autoSizingReserved |
| 03548427 | Jun–Sep 2023 | 4.12 | PLEG / CRI-O panic | podPidsLimit, maxPods, kubeAPIQPS/Burst, nodeStatusMaxImages |
| 03562048 | Jul 2023 | 4.12 | Manual node sizing | autoSizingReserved, systemReserved (10Gi recommended) |
| 03703812 | Jan 2024 | 4.12 | Kubelet GC under load | systemReserved.cpu (kubelet used 6+ cores) |
| 04046963 | Jan–Mar 2025 | 4.12 | Pod startup after drain | systemReserved (500Mi confirmed), registryPullQPS |
| 04472910 | Jun 2026 | 4.16 | Multus thread exhaustion | podPidsLimit (1024 caused failure) |

## Appendix C — References

- KCS 5843241 — Which amount of CPU and memory are recommended to reserve for the system in OpenShift 4 nodes? (https://access.redhat.com/solutions/5843241)
- KCS 7127975 — RHEL 9.4 TCP window auto-tuning regression, enic driver (https://access.redhat.com/solutions/7127975)
- OCPBUGS-15868 — CRI-O race condition, fixed in 4.12.30 (https://issues.redhat.com/browse/OCPBUGS-15868)
- RHSA-2023:4671 — CRI-O security advisory (https://access.redhat.com/errata/RHSA-2023:4671)
- OCPBUGS-27126 — High CPU usage on kubelet (https://issues.redhat.com/browse/OCPBUGS-27126)
- golang/go#14592 — Go runtime idle thread accumulation (https://github.com/golang/go/issues/14592)
- Kubernetes Node Allocatable — Upstream resource reservation docs (https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/)
- PerformanceProfile API — OCP performance tuning docs (https://docs.openshift.com/container-platform/4.16/scalability_and_performance/cnf-low-latency-tuning.html)
