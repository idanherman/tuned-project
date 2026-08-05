# Current State (Before Changes)

Capture a baseline from your cluster before applying any new Tuned CRs. This serves as the "before" snapshot for validation.

---

## Active TuneD Profiles

| Node Type | Active Profile | Applied By |
|-----------|---------------|------------|
| Control-plane | `openshift-control-plane` | NTO built-in (priority 30) |
| Infra | `openshift-control-plane` | NTO built-in (priority 30, matches infra too) |
| BM Workers | *(document existing profile here)* | Existing Tuned CR |

### What `openshift-control-plane` does (built-in)

The NTO built-in profile at priority 30. It inherits from `openshift-node` → `throughput-performance`. Key settings:

- `governor=performance` (CPU frequency scaling)
- `vm.dirty_ratio=10`, `vm.dirty_background_ratio=3`
- Does NOT set ring buffers (leaves driver defaults)
- Does NOT disable THP (inherits RHEL default: `always`)
- Does NOT set somaxconn (kernel default: 4096)

### What the existing profile does (if any)

Document the existing Tuned CR on your nodes. Key things to capture:

- Which sysctls are already set?
- Are ring buffers managed by TuneD or firmware (e.g., UCS adapter policy)?
- What GAPS exist that your new profiles need to fill?

---

## Key Metrics at Baseline

Run `scripts/collect-nic-diagnostics.sh` and record the findings here.

### VMware nodes

| Node | ring_full (TX drops) | pkts_rx_OOB | Ring RX/TX |
|------|---------------------|-------------|------------|
| *(fill in)* | | | |

### Bare-metal workers

| Node | softnet_drops | rx_no_bufs | backlog |
|------|--------------|------------|---------|
| *(fill in)* | | | |

---

## What the New Profiles Replace

| Profile | Replaces | Priority Change |
|---------|----------|-----------------|
| `vm-control-plane` | `openshift-control-plane` (built-in) | 30 → 15 |
| `vm-infra` | `openshift-control-plane` (built-in) | 30 → 16 |
| `vm-worker` | Nothing (if VMs had no custom profile) | New at 20 |
| `baremetal-*` | existing BM profile (if any) | New at 10-12 |

If the environment has an existing Tuned CR for BM workers, it should be deleted after the new profiles are applied, or its priority should be set higher (worse) than 20 so it never matches.

---

## Cluster Environment

- **OCP Version:** *(e.g., 4.16)*
- **Air-gapped:** Yes / No
- **Nodes:** N masters + N infra + N BM workers
- **VMware:** *(version, NIC driver — typically vmxnet3)*
- **Bare-metal:** *(vendor/model, NIC driver)*
- **Networking:** OVN-Kubernetes / OpenShiftSDN
- **Storage:** *(iSCSI, NFS, local — affects wmem/rmem needs)*
