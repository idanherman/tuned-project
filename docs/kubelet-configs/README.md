# KubeletConfig Divergence Analysis

> **Baseline:** live kubelet configz from a vanilla OCP 4.16.49 worker (no KubeletConfig CR applied).
> Cluster: v1.29.14+f3d9123, RHCOS 416.94, kernel 5.14.0-427.91.1.el9_4.

## OCP 4.16.49 Defaults (key fields)

These are the confirmed defaults from a running worker node with no KubeletConfig CR:

| Field | Default Value | Description |
|-------|---------------|-------------|
| `maxPods` | 250 | Maximum number of pods that can run on a node |
| `podPidsLimit` | 4096 | Maximum number of PIDs allowed per pod (changed from 1024 in OCP 4.11) |
| `nodeStatusMaxImages` | 50 | Maximum number of images reported in node status |
| `kubeAPIQPS` | 50 | Sustained QPS rate for kubelet→API server requests |
| `kubeAPIBurst` | 100 | Burst limit for kubelet→API server requests |
| `topologyManagerPolicy` | none | NUMA-aware resource alignment policy (none/best-effort/restricted/single-numa-node) |
| `imageMinimumGCAge` | 2m0s | Minimum age before an unused image is eligible for garbage collection |
| `imageGCHighThresholdPercent` | 85 | Disk usage % that triggers image GC |
| `imageGCLowThresholdPercent` | 80 | Disk usage % target after image GC runs |
| `systemReserved.cpu` | 500m | CPU reserved for OS/kubelet/CRI-O (not available to pods) |
| `systemReserved.memory` | 1Gi | Memory reserved for OS/kubelet/CRI-O (not available to pods) |
| `systemReserved.ephemeral-storage` | 1Gi | Ephemeral disk reserved for OS/kubelet/CRI-O |
| `evictionHard.memory.available` | 100Mi | Hard eviction threshold — node-level OOM prevention |
| `evictionHard.imagefs.available` | 15% | Hard eviction threshold for image filesystem |
| `evictionHard.nodefs.available` | 10% | Hard eviction threshold for node root filesystem |
| `evictionHard.nodefs.inodesFree` | 5% | Hard eviction threshold for node root filesystem inodes |
| `evictionSoft` | *(not set)* | Soft eviction thresholds — triggers graceful pod eviction before hard limit |
| `evictionPressureTransitionPeriod` | 5m0s | Cooldown before kubelet transitions out of a pressure condition |
| `allowedUnsafeSysctls` | *(not set)* | Sysctls that pods may set in their securityContext (node-level TuneD sysctls work regardless) |
| `syncFrequency` | 1m0s | How often kubelet checks for pod config changes |
| `fileCheckFrequency` | 20s | How often kubelet checks for new static pod manifests |
| `httpCheckFrequency` | 20s | How often kubelet polls HTTP endpoint for pod manifests |
| `runtimeRequestTimeout` | 2m0s | Timeout for CRI-O runtime requests (image pull, container create, etc.) |
| `streamingConnectionIdleTimeout` | 4h0m0s | Idle timeout for exec/attach/port-forward streaming sessions |
| `nodeStatusUpdateFrequency` | 10s | How often kubelet posts node status to API server |
| `nodeStatusReportFrequency` | 5m0s | How often kubelet reports full node status (if unchanged) |
| `volumeStatsAggPeriod` | 1m0s | How often kubelet computes per-volume disk usage stats |
| `authentication.webhook.cacheTTL` | 2m0s | How long kubelet caches authentication webhook results |
| `authorization.webhook.cacheAuthorizedTTL` | 5m0s | How long kubelet caches successful authorization decisions |
| `authorization.webhook.cacheUnauthorizedTTL` | 30s | How long kubelet caches rejected authorization decisions |
| `logging.verbosity` | 2 | Kubelet log verbosity level (0=minimal, 5+=trace) |
| `logging.flushFrequency` | 5s | How often kubelet flushes log buffers |
| `shutdownGracePeriod` | 0s | Time kubelet gives pods to terminate during node shutdown (0=disabled) |
| `shutdownGracePeriodCriticalPods` | 0s | Portion of shutdownGracePeriod reserved for critical pods |
| `autoSizingReserved` | *(not set / false)* | OCP-specific: auto-calculate systemReserved based on node capacity using sizing formula |

---

## Case Archive Lore

Historical support cases that explain why specific KubeletConfig settings were chosen.
Source: 83 cases from the customer archive, cross-referenced against each divergent setting.

### Case 03548427 — The parent case (PLEG / CRI-O panic, OCP 4.12, Jun–Sep 2023)

The "master reference" case for this cluster's kubelet tuning. After upgrading from OCP 4.12.2
to 4.12.15, workers went NotReady with PLEG failures and CRI-O panics ("close of closed channel").
Cisco UCS bare-metal nodes (56 cores, 756GB RAM) with NetApp iSCSI. This single case is the
origin of most current KubeletConfig settings:

**Timeline of config changes during the crisis:**
- **Jun 29**: KubeletConfig dump shows original state: `autoSizingReserved: true`, `maxPods: 500`,
  `nodeStatusMaxImages: 500`, `allowedUnsafeSysctls: [net.core.somaxconn]`
- **Jul 2** (Daniel Eidel, PS consultant): *"We have notice a very high amount (over 10000 in
  some cases) of zombie process held by customer workloads. We are attempting to restrict container
  PIDs to 1024 (default value in 4.10) to possibly improve the situation"*
- **Jul 3** (Ido Pal): *"Changed pids_limit to 1024 on all workers"*
- **Jul 5** (Internal update): *"CU tried the crio wipe and reduced the pid limit to 1024 and
  still faced the issue with the nodes"* — **the PID limit did not fix the issue**
- **Jul 5** (Henik, Idan): Investigation split into two vectors:
  1. *"The KubeletConfig Contains maxpods value of '500' but with the default kubeAPIBurst and
     KubeAPIQPS values. NOTE that the hostprefix is stand on 23 instead of the recommended 22"*
  2. CRI-O code race condition (the actual root cause)
- **Jul 5** (Barak Vaturi): *"what are the recommended kubeAPIQPS and kubeAPIBrust?"*
  CEE confirmed: *"modifying KubeAPIQPS and kubeAPIBurst is supported"*
- **Jul 6** (Anoel): Changed kubeletconfig: decreased maxPods to 400, increased `kubeAPIQPS`
  to 100 (from 50) and `kubeAPIBurst` to 200 (from 100)
- **Jul 17** (Anoel): Customer decided to keep auto-sizing, split cluster into two pools
  (13 workers at maxPods=250, 13 at maxPods=500)

**Root cause:** CRI-O race condition (OCPBUGS-15868), fixed in OCP 4.12.30 (RHSA-2023:4671).

### Case 03562048 — Manual node sizing (child of 03548427, OCP 4.12, Jul 2023)

Red Hat engineering recommended disabling `autoSizingReserved` and manually configuring
`systemReserved`. The auto-sizing formula yielded CPU=210m and Memory=22Gi for 56-core/756GB
workers. Engineering's recommendation: **cpu: 4000m, memory: 10Gi**.

The customer's actual auto-sizing values at the time:
- Masters (20 vCPU, 130GB): `system_reserved_memory=9Gi, system_reserved_cpu=0.1175, system_reserved_es=1Gi`
- Infra VMs (12 vCPU, 42GB): `system_reserved_memory=4Gi, system_reserved_cpu=0.1, system_reserved_es=1Gi`
- Workers BM (56 CPU, 756GB): `system_reserved_memory=22Gi, system_reserved_cpu=0.21, system_reserved_es=1Gi`

Customer decided: *"our auto-sizing values are very close to the manual changes proposed...
I don't think we should change auto-sizing to manual values, at least not for now."*

> **Key finding:** Engineering recommended `memory: 10Gi`, but the current tuned-worker config
> has `memory: 500Mi`. The CPU recommendation of 4000m was adopted; the memory recommendation
> was not — it was somehow reduced from 10Gi (recommended) to 500Mi (20x lower than recommended).

### Case 03502380 — Eviction thresholds best practices (OCP 4.8, May 2023)

Customer asked about recommended `evictionSoft`, `evictionSoftGracePeriod`, and `evictionHard`
values after a node crash from excessive memory usage. Red Hat confirmed: defaults for
`evictionSoft` and `evictionSoftGracePeriod` are nil (no effect unless configured). No universal
recommended values — they are cluster/load-specific.

### Case 03703812 — Kubelet GC under high load (OCP 4.12, Jan 2024)

Workers with `maxPods=500` and `systemReserved` at 4 CPU cores + 20GB RAM had load averages
over 100. Kubelet consumed up to 6 CPU cores (exceeding the 4-core reservation). `pprof` showed
GC (garbage collection) as the most time-consuming kubelet process. Failed/error pods were
accumulating and causing kubelet GC loops. Resolved by: *"launched a script that deletes all the
pods stuck in error and now the cluster seems more stable."*

> **Key finding:** This case confirms `systemReserved.cpu: 4000m` is justified — kubelet alone
> can consume 6+ cores under GC pressure with 500 maxPods.

### Case 04046963 — Pod startup delay after drain (OCP 4.12, Jan–Mar 2025)

300-400 pods restarting simultaneously after node drain caused CRI-O context deadline exceeded
errors and OVS database connection failures. Customer reported:
*"configured system reserve in the kubeletconfig of 4 cores, 500Mi memory and 1Gi storage"*

They later tried increasing to 8 cores and 5Gi memory with no improvement: *"We tried increasing
the CPU and memory from 4 Cores to 8 Cores and 0.5Gi to 5Gi. It didn't seem to improve the time
that it takes the pods to become ready."*

Also configured `registryPullQPS: 50` and `registryBurst: 100` to resolve pull QPS exceeded errors.

> **Key finding:** This is the earliest confirmation that `systemReserved.memory` was already at
> 500Mi (Feb 2025). The value was never the recommended 10Gi from Case 03562048.

### Case 04472910 — Multus thread exhaustion (OCP 4.16, Jun 2026)

**Directly relevant — this is a current OCP 4.16 case.** Multus daemon hit `pids.max=1024` due
to Go runtime thread accumulation during OVS/OVN stalls. Burst waves of Airflow importer pods
triggered the failure chain. Red Hat recommended:
1. Set `podPidsLimit` to 4096 (OCP 4.11+ default; production had legacy 1024)
2. Add more worker nodes
3. Use taints/tolerations to isolate burst workloads

---

## master-kubeletconfig

**1 divergence from defaults.**

| Field | OCP Default | Customer Value | | Origin | Notes |
|-------|-------------|----------------|---|--------|-------|
| `autoSizingReserved` | not set | **true** | | Case 03548427 | Overrides static systemReserved with auto-calculated values based on node capacity |

No `kubeletConfig` overrides at all — the only change is enabling auto-sizing.

---

## infra-kubeletconfig

**5 divergences from defaults.**

| Field | OCP Default | Customer Value | | Origin | Notes |
|-------|-------------|----------------|---|--------|-------|
| `autoSizingReserved` | not set | **true** | | Case 03548427 | Auto-calculates system reserves |
| `allowedUnsafeSysctls` | *(none)* | **net.core.somaxconn** | | *(no case lore found)* | Enables pod-level somaxconn override; complements node-level TuneD setting |
| `maxPods` | 250 | **100** | lowered | *(no case lore found)* | Infra nodes typically run fewer, heavier pods (routers, monitoring) |
| `nodeStatusMaxImages` | 50 | **250** | raised 5x | *(no case lore found)* | Reports more images in node status |
| `podPidsLimit` | 4096 | **1024** | ⚠️ lowered 4x | Case 03548427 / 04472910 | Emergency measure (Jul 2023) against zombie processes during CRI-O panic. Did not fix the issue. Later caused Multus thread exhaustion on OCP 4.16 |

---

## normal-worker-kubeletconfig

**3 divergences from defaults.** Clean and minimal.

| Field | OCP Default | Customer Value | | Origin | Notes |
|-------|-------------|----------------|---|--------|-------|
| `autoSizingReserved` | not set | **true** | | Case 03548427 | Auto-calculates system reserves |
| `allowedUnsafeSysctls` | *(none)* | **net.core.somaxconn** | | *(no case lore found)* | Enables pod-level somaxconn override |
| `maxPods` | 250 | **500** | raised 2x | Case 03548427 | High-density worker nodes; originally set, temporarily reduced to 400 during PLEG crisis, restored after CRI-O fix |

---

## tuned-worker-kubeletconfig

**23 intentional divergences + 14 zero-value config dump artifacts.**

> ⚠️ **Config dump artifact detected**
>
> This config contains `kind: KubeletConfiguration` and `apiVersion: kubelet.config.k8s.io/v1beta1`
> nested inside `.spec.kubeletConfig`, plus 14 fields explicitly set to `0s`/`0`. This indicates
> the config was extracted from a running kubelet (e.g. via configz or `oc debug`) rather than
> authored from scratch. The zero-value fields are applied literally by MCO even though the kubelet
> internally treats most `0s` durations as "use compiled default."

### Intentional divergences

| Field | OCP Default | Customer Value | | Origin | Notes |
|-------|-------------|----------------|---|--------|-------|
| `autoSizingReserved` | true (on other roles) | **not set** | ⚠️ missing | Case 03562048 | Engineering recommended manual sizing for BM workers; customer initially declined but later adopted for tuned pool only |
| `systemReserved.cpu` | 500m | **4000m** | raised 8x | Case 03562048 / 03703812 | Engineering recommended 4000m (Jul 2023). Case 03703812 confirmed kubelet alone consumes 6+ cores under GC pressure with 500 maxPods |
| `systemReserved.memory` | 1Gi | **500Mi** | 🔴 halved | Case 04046963 | Engineering recommended **10Gi** in Case 03562048, but the actual config has 500Mi — confirmed in Case 04046963 (Feb 2025). This value was never the recommended 10Gi |
| `systemReserved.ephemeral-storage` | 1Gi | **not set (0)** | ⚠️ missing | | Auto-sizing default includes `system_reserved_es=1Gi`; this was lost when switching to manual |
| `allowedUnsafeSysctls` | *(none)* | **net.core.somaxconn** | | Case 03548427 | Part of original config; enables pod-level somaxconn override |
| `maxPods` | 250 | **500** | raised 2x | Case 03548427 | Originally set, temporarily reduced to 400 during crisis, restored after CRI-O fix |
| `nodeStatusMaxImages` | 50 | **500** | raised 10x | Case 03548427 | Part of original config; accommodates large image cache on bare-metal nodes |
| `podPidsLimit` | 4096 | **1024** | ⚠️ lowered 4x | Case 03548427 / 04472910 | Emergency measure (Jul 3, 2023) to combat 10,000+ zombie processes during CRI-O panic crisis. **Did not fix the issue.** The real fix was the CRI-O bugfix in 4.12.30. Never reverted. Case 04472910 (Jun 2026, OCP 4.16) later confirmed this legacy value caused Multus thread exhaustion |
| `kubeAPIQPS` | 50 | **100** | raised 2x | Case 03548427 | Changed Jul 6, 2023 after CEE confirmed it is supported. Supports higher pod count with faster API communication |
| `kubeAPIBurst` | 100 | **200** | raised 2x | Case 03548427 | Changed alongside kubeAPIQPS |
| `topologyManagerPolicy` | none | **best-effort** | changed | *(no case lore found)* | Enables NUMA-aware scheduling; relevant for future IRQ affinity pinning work |
| `imageMinimumGCAge` | 2m0s | **5m** | raised | *(no case lore found)* | More lenient; images kept longer before GC eligibility |
| `imageGCHighThresholdPercent` | 85 | **75** | lowered | *(no case lore found)* | GC triggers 10% sooner; more aggressive disk management |
| `imageGCLowThresholdPercent` | 80 | **50** | lowered | *(no case lore found)* | GC frees down to 50% vs 80%; much more aggressive cleanup |
| `evictionSoft.memory.available` | *(not set)* | **16000Mi** | ⚠️ new | Case 03502380 | Customer asked about eviction best practices (May 2023); no universal values recommended |
| `evictionSoft.imagefs.available` | *(not set)* | **25%** | new | | |
| `evictionSoft.nodefs.available` | *(not set)* | **20%** | new | | |
| `evictionSoft.nodefs.inodesFree` | *(not set)* | **15%** | new | | |
| `evictionSoft.imagefs.inodesFree` | *(not set)* | **10%** | new | | |
| `evictionHard.memory.available` | 100Mi | **8000Mi** | ⚠️ raised 80x | Case 03502380 | Hard-evicts at <8GB free memory; assumes large-memory (756GB) nodes |
| `evictionHard.imagefs.available` | 15% | **10%** | lowered | | More tolerant of disk usage |
| `evictionHard.imagefs.inodesFree` | *(not set)* | **5%** | new | | |
| `evictionSoftGracePeriod (all signals)` | *(not set)* | **1m30s** | new | | Very short grace; pods get 90 seconds before eviction |

### Zero-value fields (config dump artifacts)

These fields are explicitly set to `0s` or `0` in the customer config. They were almost certainly
included when the config was dumped from a running kubelet — Go serialization writes zero values
for all unset `Duration`/`int` fields. The kubelet internally defaults most of these, but they
add noise and fragility across OCP upgrades.

| Field | OCP Default | Risk |
|-------|-------------|------|
| `syncFrequency` | 1m0s | Low: kubelet treats 0s as compiled default |
| `fileCheckFrequency` | 20s | Low: kubelet treats 0s as compiled default |
| `httpCheckFrequency` | 20s | Low: kubelet treats 0s as compiled default |
| `runtimeRequestTimeout` | 2m0s | Low: kubelet treats 0s as compiled default |
| `streamingConnectionIdleTimeout` | 4h0m0s | Medium: 0s could mean no timeout on exec/attach sessions |
| `nodeStatusReportFrequency` | 5m0s | Low: kubelet treats 0s as compiled default |
| `nodeStatusUpdateFrequency` | 10s | Low: kubelet treats 0s as compiled default |
| `evictionPressureTransitionPeriod` | 5m0s | Medium: 0s means immediate transition between pressure states |
| `volumeStatsAggPeriod` | 1m0s | Low: kubelet treats 0s as compiled default |
| `authentication.webhook.cacheTTL` | 2m0s | Medium: 0s disables authn cache; every request hits API server |
| `authorization.webhook.cacheAuthorizedTTL` | 5m0s | Medium: 0s disables authz cache; increased API server load |
| `authorization.webhook.cacheUnauthorizedTTL` | 30s | Low: slightly more API calls for denied requests |
| `logging.verbosity` | 2 | Low: reduces kubelet logging (may hide useful diagnostics) |
| `logging.flushFrequency` | 5s | Low: kubelet uses compiled default |

---

## Interactions with TuneD CRs

| Interaction | KubeletConfig Setting | TuneD Setting | Assessment |
|-------------|----------------------|---------------|------------|
| **Pod somaxconn override** | `allowedUnsafeSysctls` on infra/worker/tuned | `vm-infra`: somaxconn=10240 | ✅ Aligned — node-level TuneD + pod-level kubelet enablement |
| **Memory pressure vs TCP buffers** | Soft eviction at 16GB, hard at 8GB | rmem_max=16MB, wmem_max=16MB | ⚠️ Risk — kernel buffer memory not in cgroups; erodes available memory toward eviction line |
| **Image GC + enic slow-pull** | GC at 75%/50%, imageMinGCAge: 5m | `baremetal-cisco-enic`: tcp_rmem fix | ⚠️ Dependency — TuneD tcp_rmem fix must land before image churn on enic nodes |
| **NUMA topology + future IRQ affinity** | topologyManagerPolicy: best-effort | IRQ affinity pinning (deferred) | ✅ Complementary — topology manager will co-locate with pinned NIC IRQs when implemented |
| **Pod density + API rate** | maxPods: 500, QPS: 100, Burst: 200 | Large ring buffers + backlog tuning | ✅ Aligned — high pod density with tuned network stack |

---

## Recommendations

### 🔴 1. Raise `podPidsLimit` from 1024 to 4096 on all node roles — IMMEDIATELY

**Origin:** Case 03548427 (Jul 3, 2023) — emergency measure during CRI-O panic crisis to combat
10,000+ zombie processes. The PS consultant noted 1024 was the "default value in 4.10." Internal
update on Jul 5 confirmed: *"CU tried the crio wipe and reduced the pid limit to 1024 and still
faced the issue with the nodes."* The setting **did not fix the problem** (the real fix was the
CRI-O bugfix in 4.12.30) and was never reverted.

**Current impact:** Case 04472910 (Jun 2026, OCP 4.16.50) confirms this legacy value directly
caused Multus thread exhaustion when burst pod creation triggered OVS/OVN stalls. Go runtime
thread accumulation (60→75→82→1024) hit the `pids.max` ceiling. Red Hat recommended raising to
4096 immediately.

**Action:** The original justification (CRI-O panic bug) was fixed in 4.12.30. The value has
since caused a new production failure on OCP 4.16. Raise `podPidsLimit` to 4096 (OCP 4.11+
default) on infra-kubeletconfig and tuned-worker-kubeletconfig.

### 🔴 2. Fix `systemReserved.memory` on tuned-worker — investigate the 500Mi origin

**Origin:** Case 03562048 (Jul 2023) recommended `systemReserved: cpu: 4000m, memory: 10Gi`.
The CPU value (4000m) was adopted. The memory value was not — the current config has 500Mi,
which is 20x lower than the engineering recommendation and half the OCP default (1Gi). Case
04046963 (Feb 2025) confirms 500Mi was already in place at that time.

The auto-sizing formula for 56-core/756GB workers calculated `system_reserved_memory=22Gi`.
Red Hat engineering proposed reducing that to 10Gi. Somehow the actual value ended up at 500Mi.

[KCS 5843241](https://access.redhat.com/solutions/5843241) explicitly warns: *"Changing default
values (like for example the podPidsLimit or the maxPods for the KubeletConfig) could require to
reserve more CPU and/or memory for the system resources, so the automatic reservation could be not
enough for specific configurations."* Internal notes on the same KCS add: *"For large nodes →
500 pods per node — automatic reservation is not allocating enough CPU."* With `maxPods=500`,
even auto-sizing's 22Gi is considered potentially insufficient — 500Mi is indefensible.

**Comparison for 56-core / 756GB bare-metal nodes (OCP 4.16):**

| Source | CPU | Memory | Eph-Storage |
|--------|-----|--------|-------------|
| Auto-sizing (calculated for this HW) | 210m | **22 Gi** | 1Gi |
| Case 03562048 confirmed `/etc/node-sizing.env` | 210m | **22 Gi** | 1Gi |
| RH Engineering recommended (Case 03562048) | 4000m | **10 Gi** | 1Gi |
| OCP static default (no auto-sizing) | 500m | **1 Gi** | 1Gi |
| **Customer actual (tuned-worker)** | 4000m | **500 Mi** | **not set** |

- Customer vs auto-sizing: 500Mi / 22Gi = **2.2% — 45x under-reserved**
- Customer vs RH engineering recommendation: 500Mi / 10Gi = **4.9% — 20x under-reserved**
- Customer vs OCP static default: 500Mi / 1Gi = **48.8% — 2x under-reserved**

**Action:** Increase to at least 10Gi per the original engineering recommendation. The KCS warns
that even auto-sizing (22Gi) may not be enough for `maxPods=500` nodes, and the TuneD TCP buffer
tuning (rmem_max/wmem_max = 16MB) adds additional kernel memory pressure outside pod cgroup
tracking.

### ⚠️ 3. Clean up zero-value config dump artifacts

Remove the 14 explicitly-zeroed fields, the embedded `kind`/`apiVersion`, and the redundant
`logging`/`authentication`/`authorization` blocks from tuned-worker-kubeletconfig. These add no
value and make the config fragile across OCP upgrades if kubelet defaults change. The config
should only contain intentional divergences.

### ⚠️ 4. Add `ephemeral-storage` to tuned-worker systemReserved

The OCP default and auto-sizing both reserve 1Gi ephemeral-storage (`system_reserved_es=1Gi`
confirmed in Case 03562048). The tuned-worker omits this entirely — likely lost when switching
from `autoSizingReserved` to manual `systemReserved`.

### ℹ️ 5. Document the memory eviction budget

The 16GB soft / 8GB hard eviction thresholds were configured for 756GB bare-metal nodes.
Calculate the effective memory budget:

```
effective_pod_memory = capacity - systemReserved - evictionHard.memory - estimated_kernel_buffer_overhead
```

For a 756GB node:
- capacity: 756Gi
- systemReserved: 500Mi (current) → should be 10Gi per Case 03562048 recommendation
- eviction hard threshold: 8Gi
- kernel buffer overhead (estimated with tuned TCP settings): 2-8Gi depending on connection count
- **effective for pods: ~738Gi** (but only because systemReserved.memory is too low)
- **with recommended 10Gi reserve: ~730Gi** (safer margin for kubelet/CRI-O/kernel)

---

## Cross-reference: Case archive summary

| Case | Date | OCP | Topic | Settings affected |
|------|------|-----|-------|-------------------|
| 03502380 | May 2023 | 4.8 | Eviction best practices | `evictionSoft`, `evictionHard`, `autoSizingReserved` |
| 03548427 | Jun–Sep 2023 | 4.12 | PLEG / CRI-O panic (parent case) | `podPidsLimit`, `maxPods`, `kubeAPIQPS/Burst`, `nodeStatusMaxImages`, `autoSizingReserved`, `allowedUnsafeSysctls` |
| 03562048 | Jul 2023 | 4.12 | Manual node sizing | `autoSizingReserved`, `systemReserved` (cpu: 4000m, memory: 10Gi recommended) |
| 03703812 | Jan 2024 | 4.12 | Kubelet GC under high load | `systemReserved.cpu` (4 cores insufficient; kubelet used 6+), `maxPods` |
| 04046963 | Jan–Mar 2025 | 4.12 | Pod startup delay after drain | `systemReserved` (500Mi confirmed), `registryPullQPS/Burst` |
| 04472910 | Jun 2026 | 4.16 | Multus thread exhaustion | `podPidsLimit` (1024 caused failure; raise to 4096) |
