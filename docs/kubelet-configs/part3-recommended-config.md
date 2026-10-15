# PART 3 — Recommended Configuration

---

## §15 — Rollout Plan

Changes must be applied in order. Each phase has different impact and risk.

### Phase 1: TuneD Profiles (no reboot, immediate effect)

| Action | Profile | Target nodes | Risk |
|--------|---------|-------------|------|
| Deploy enic tcp_rmem fix | baremetal-cisco-b200 | All Cisco blade workers | **Low** — sysctl change, no service restart. CRITICAL for image pull regression. |
| Deploy i40e ring+coalesce | baremetal-cisco-c220 | All Cisco pizza workers | **Low** — ring buffer increase. Eliminates 12.7M rx_missed_errors. |
| Deploy bnxt_en ring+features | baremetal-dell-r6625 | All Dell R6625 workers | **Low** — ring buffer increase from 511 to 2047. |
| Deploy VM profiles | vm-infra, vm-worker, vm-control-plane | All VMs | **Low** — sysctls and ring buffers. |

**Pre-requisite:** Label nodes with NIC driver:
```
oc label node <name> node.kubernetes.io/nic-driver=enic      # Cisco blades
oc label node <name> node.kubernetes.io/nic-driver=i40e       # Cisco pizza
oc label node <name> node.kubernetes.io/nic-driver=bnxt_en    # Dell R6625
```

**Validation after Phase 1:**
```
# Verify TuneD profile is active on each node:
oc get nodes -o custom-columns=NAME:.metadata.name,PROFILE:.metadata.annotations."tuned\.openshift\.io/applied-profile"

# Check ring buffers increased:
oc debug node/<node> -- chroot /host ethtool -g eth0

# Monitor rx_missed_errors / rx_no_bufs (should stop incrementing):
oc debug node/<node> -- chroot /host ethtool -S eth0 | grep -E "missed|no_buf"
```

### Phase 2: KubeletConfig Fixes (MCO rolling reboot per pool)

Each KubeletConfig change triggers an MCO rollout — nodes drain, reboot, and rejoin one by one. Plan maintenance windows.

| Action | Pool | Impact |
|--------|------|--------|
| Raise podPidsLimit to 4096 | infra-kubeletconfig | MCO reboot of infra nodes |
| Raise podPidsLimit to 4096 | tuned-worker-kubeletconfig | MCO reboot of tuned-worker nodes |
| Raise systemReserved.memory to 10Gi | tuned-worker-kubeletconfig | Same reboot as above (batch changes) |
| Add systemReserved.ephemeral-storage: 1Gi | tuned-worker-kubeletconfig | Same reboot |
| Remove 14 zero-value dump artifacts | tuned-worker-kubeletconfig | Same reboot |
| Raise kubeAPIQPS/Burst to 100/200 | normal-worker-kubeletconfig | MCO reboot of normal-worker nodes |

**Batch changes per pool** to minimize reboots. Apply all tuned-worker changes in one KubeletConfig update.

**Validation after Phase 2:**
```
# Verify podPidsLimit on a node:
oc debug node/<node> -- chroot /host cat /etc/kubernetes/kubelet.conf | grep podPidsLimit

# Verify systemReserved:
oc debug node/<node> -- chroot /host cat /etc/node-sizing.env
```

### Phase 3: PerformanceProfiles (MCO rolling reboot, per hardware type)

Deploy only when Phase 1 and 2 are stable. Each PerformanceProfile creates a KubeletConfig, MachineConfig, and TuneD behind the scenes.

**Pre-requisites:**
1. Create hardware-type MCP labels (add to per-node MCPs)
2. Add `cisco-b200` / `dell-r6625` / `cisco-c220` to each per-node MCP's machineConfigSelector
3. Delete the old KubeletConfig for that pool AFTER the PP is active

| Action | Target | CPU Pinning |
|--------|--------|------------|
| PerformanceProfile cisco-b200 | Cisco B200 M5 blades | reserved: 0-5,14-15,28-33,42-43 (16 logical, weighted NUMA 0) |
| PerformanceProfile dell-r6625 | Dell R6625 | reserved: 0-3,32-33,64-67,96-97 (12 logical, balanced) |
| PerformanceProfile cisco-c220 | Cisco C220-M5SX | reserved: 0-3,16-17,32-35,48-49 (12 logical, balanced) |

Phase 3 is a **performance optimization**, not a bug fix. The customer can operate safely with just Phase 1 + 2.

---

## §16 — Target KubeletConfigs

After Phase 2, each pool's KubeletConfig should contain ONLY intentional divergences from defaults. All zero-value dump artifacts and ineffective settings removed.

### master-kubeletconfig (no changes needed)

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

### normal-worker-kubeletconfig (add QPS, consider manual sizing)

```yaml
kind: KubeletConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: normal-worker-kubeletconfig
spec:
  autoSizingReserved: true        # consider switching to manual sizing (see tuned-worker)
  kubeletConfig:
    allowedUnsafeSysctls:
      - net.core.somaxconn
    maxPods: 500
    kubeAPIQPS: 100               # was 50 (default) — ADDED
    kubeAPIBurst: 200             # was 100 (default) — ADDED
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
    # Pod density
    maxPods: 500
    podPidsLimit: 4096                      # was 1024 — FIXED
    kubeAPIQPS: 100
    kubeAPIBurst: 200
    nodeStatusMaxImages: 500
    # System resources
    systemReserved:
      cpu: 4000m
      memory: 10Gi                          # was 500Mi — FIXED (per Case 03562048 recommendation)
      ephemeral-storage: 1Gi               # was missing — ADDED
    # Eviction
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
    # Image GC
    imageGCHighThresholdPercent: 75
    imageGCLowThresholdPercent: 50
    imageMinimumGCAge: 5m
    # Registry
    registryPullQPS: 50
    registryBurst: 100
    # Networking
    allowedUnsafeSysctls:
      - net.core.somaxconn
    # Shutdown
    shutdownGracePeriod: 90s
    shutdownGracePeriodCriticalPods: 15s
    # NOTE: topologyManagerPolicy removed — no effect without cpuManagerPolicy: static
    # NOTE: All 14 zero-value dump artifacts removed
    # NOTE: Embedded kind/apiVersion removed
  machineConfigPoolSelector:
    matchLabels:
      kubelet: tuned-worker-kubeletconfig
```

**What was removed vs the current config:**
- `kind: KubeletConfiguration` / `apiVersion: kubelet.config.k8s.io/v1beta1` (embedded metadata — dump artifact)
- `topologyManagerPolicy: best-effort` (no effect without cpuManagerPolicy: static)
- 14 zero-value fields (syncFrequency: 0s, fileCheckFrequency: 0s, httpCheckFrequency: 0s, runtimeRequestTimeout: 0s, streamingConnectionIdleTimeout: 0s, nodeStatusReportFrequency: 0s, nodeStatusUpdateFrequency: 0s, evictionPressureTransitionPeriod: 0s, volumeStatsAggPeriod: 0s, authentication.webhook.cacheTTL: 0s, authorization.webhook.cacheAuthorizedTTL: 0s, authorization.webhook.cacheUnauthorizedTTL: 0s, logging.verbosity: 0, logging.flushFrequency: 0)
- `memorySwap: {}` (empty object, dump artifact)
- `authentication` / `authorization` / `logging` blocks (dump artifacts with zero values)

---

## §17 — Target TuneD Profiles

| Profile | NIC driver | Ring buffer | Key settings | Status |
|---------|-----------|-------------|-------------|--------|
| baremetal-cisco-b200 | enic | N/A (UCSM) | tcp_rmem=4096 3145728 6291456, backlog=5000, budget=600 | Ring/coalesce set at UCSM adapter policy |
| baremetal-cisco-c220 | i40e | rx 8160 tx 8160 | coalesce=125µs fixed, ntuple on, rx-gro-hw on, backlog=5000 | New — for pizza servers |
| baremetal-dell-r6625 | bnxt_en | rx 2047 tx 2047 | coalesce=adaptive, ntuple on, rx-gro-hw on, backlog=5000 | Updated — ring max corrected |
| vm-infra | vmxnet3 | rx 4096 | somaxconn=10240, backlog=8192, file-max=2M, THP=always | Ready |
| vm-worker | vmxnet3 | rx 4096 | THP=never | Ready |
| vm-control-plane | vmxnet3 | rx 4096 | THP=always (etcd/API benefit) | Ready |

**Per-driver capability matrix:**

| Capability | enic (Cisco VIC) | i40e (Intel X710) | bnxt_en (Broadcom) | vmxnet3 (VMware) |
|------------|:---:|:---:|:---:|:---:|
| Ring via TuneD | ✗ (UCSM) | ✓ | ✓ | ✓ |
| Coalesce via TuneD | ✗ (UCSM) | ✓ | ✓ | ✗ |
| Channels via TuneD | ✗ (UCSM) | ✓ | ✓ | ✗ |
| ntuple (aRFS) | ✗ (not supported) | ✓ | ✓ | ✗ |
| GRO-HW | ✗ (not supported) | ✗ (fixed off on C220) | ✓ | ✗ |
| RSS | via UCSM | auto (1:1 CPU) | via ethtool | limited |

---

## §18 — Target PerformanceProfiles

Deploy in Phase 3 only. Each replaces the KubeletConfig for that hardware type.

### Cisco B200 M5 (blade)

```yaml
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
metadata:
  name: cisco-b200
  annotations:
    kubeletconfig.experimental: |
      {"maxPods":500,"podPidsLimit":4096,"kubeAPIQPS":100,"kubeAPIBurst":200,
       "nodeStatusMaxImages":500,"registryPullQPS":50,"registryBurst":100,
       "systemReserved":{"memory":"10Gi","ephemeral-storage":"1Gi"},
       "allowedUnsafeSysctls":["net.core.somaxconn"],
       "evictionHard":{"memory.available":"8Gi","imagefs.available":"10%","nodefs.available":"10%","nodefs.inodesFree":"5%"},
       "evictionSoft":{"memory.available":"16Gi","imagefs.available":"25%","nodefs.available":"20%","nodefs.inodesFree":"15%","imagefs.inodesFree":"10%"},
       "evictionSoftGracePeriod":{"memory.available":"1m30s","imagefs.available":"1m30s","nodefs.available":"1m30s","nodefs.inodesFree":"1m30s","imagefs.inodesFree":"1m30s"},
       "imageGCHighThresholdPercent":75,"imageGCLowThresholdPercent":50,"imageMinimumGCAge":"5m0s",
       "shutdownGracePeriod":"90s","shutdownGracePeriodCriticalPods":"15s"}
spec:
  cpu:
    # Socket 0 (NIC NUMA): 6 phys cores + HT = 12 logical
    # Socket 1: 2 phys cores + HT = 4 logical
    reserved: "0-5,14-15,28-33,42-43"
    isolated: "6-13,16-27,34-41,44-55"
  numa:
    topologyPolicy: "restricted"
  realTimeKernel:
    enabled: false
  globallyDisableIrqLoadBalancing: false
  machineConfigPoolSelector:
    matchLabels:
      hw-type: cisco-b200
  machineConfigLabel:
    machineconfiguration.openshift.io/role: cisco-b200
  nodeSelector:
    node.kubernetes.io/hw-type: cisco-b200
```

**Why 6 cores on socket 0, 2 on socket 1:** All 4 NICs + iSCSI are on NUMA 0. 32 RX queues fire IRQs there. kubelet GC can spike to 6+ cores. Socket 1 only needs cores for systemd and kernel threads without NIC locality requirements.

### Dell R6625

Defer until production workload is deployed. CPU reservation layout for when ready:

```yaml
spec:
  cpu:
    # Socket 0 (NIC NUMA): 4 phys cores + HT = 8 logical
    # Socket 1: 2 phys cores + HT = 4 logical
    # 128 total → 12 reserved, 116 isolated (plenty of headroom)
    reserved: "0-3,32-33,64-67,96-97"
    isolated: "4-31,34-63,68-95,98-127"
```

### Cisco C220-M5SX (pizza)

Defer until ring buffer fix is applied and impact measured. Layout for when ready:

```yaml
spec:
  cpu:
    # Socket 0 (NIC NUMA): 4 phys cores + HT = 8 logical
    # Socket 1: 2 phys cores + HT = 4 logical
    reserved: "0-3,16-17,32-35,48-49"
    isolated: "4-15,18-31,36-47,50-63"
```

---

## §19 — Hardware-Level Configuration

Some settings cannot be changed via OpenShift (TuneD, KubeletConfig, PerformanceProfile). They must be configured at the hardware management level.

### Cisco UCS (UCSM for B-series blades, CIMC for C-series rack)

| Setting | Where to configure | Current value | Recommended |
|---------|-------------------|---------------|-------------|
| Ring buffers (RX/TX) | UCSM → Service Profile → vNIC → Adapter Policy | 4096 (blades) | 4096 ✓ |
| Queue count (RX/TX) | UCSM → Adapter Policy → Receive Queue Count | 8 | 8 ✓ |
| RSS | UCSM → Adapter Policy → RSS | Enabled | Enabled ✓ |
| Interrupt coalescing | UCSM → Adapter Policy → Interrupt Coalescing Timer | 125µs | 125µs ✓ |
| Interrupt count | UCSM → Adapter Policy → Interrupt Count | 32 | 32 ✓ |

**Note:** For C220 pizza servers using i40e (Intel X710), these settings are controlled via ethtool/TuneD, NOT CIMC. The ixgbe NIC (eno2) if activated would need CIMC configuration.

### Dell (iDRAC)

No NIC-level configuration needed in iDRAC for bnxt_en. All settings managed via ethtool/TuneD.

**BIOS NPS setting:** Verify NPS1 (NUMA-per-socket = 1) is configured. This gives 2 NUMA nodes (one per socket). NPS2 or NPS4 would split each socket into multiple NUMA domains, complicating CPU pinning.

```
iDRAC → BIOS Settings → Processor Settings → NUMA Nodes Per Socket = 1
```
