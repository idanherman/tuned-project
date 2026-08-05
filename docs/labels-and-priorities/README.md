# NTO Structure — Priority and Label Design

How the profiles are deployed via the Node Tuning Operator. This defines WHICH nodes get WHICH profile and in what order of precedence.

---

## Priority Rules (NTO evaluation)

- Lower number = higher priority (evaluated first)
- NTO walks the recommendations array in ascending priority order
- First match wins — stops evaluating further
- Default `openshift-control-plane` is priority 30, `openshift-node` is priority 40
- Custom profiles must be LOWER number (higher priority) to take precedence
- Multiple items in a `match` array are **AND conditions** — use separate recommend entries for OR logic

---

## Current Implementation

This framework deploys **one Tuned CR per profile** (6 total) for independent lifecycle management. See `manifests/` for the actual YAMLs.

| Priority | CR Name | Profile | Match Label |
|----------|---------|---------|-------------|
| 10 | baremetal-cisco-enic | baremetal-cisco-enic | `node.kubernetes.io/nic-driver=enic` |
| 11 | baremetal-cisco-i40e | baremetal-cisco-i40e | `node.kubernetes.io/nic-driver=i40e` |
| 12 | baremetal-dell-r6625 | baremetal-dell-r6625 | `node.kubernetes.io/nic-driver=bnxt_en` |
| 15 | vm-control-plane | vm-control-plane | `node-role.kubernetes.io/control-plane` + `tuning.custom/ring-resize=true` |
| 16 | vm-infra | vm-infra | `node-role.kubernetes.io/infra` |
| 20 | vm-worker | vm-worker | `node-role.kubernetes.io/worker` |
| 30 | *(built-in)* | openshift-control-plane | *(default, overridden by custom)* |
| 40 | *(built-in)* | openshift-node | *(default, overridden by custom)* |

---

## Label Strategy

### Option A: Custom labels (explicit, requires manual labeling) — CHOSEN

```bash
oc label node <bm-worker-1> node.kubernetes.io/nic-driver=enic
oc label node <bm-worker-2> node.kubernetes.io/nic-driver=i40e
oc label node <bm-worker-3> node.kubernetes.io/nic-driver=bnxt_en
```

Pros: Explicit, no ambiguity, works regardless of node detection.
Cons: Must label every node manually (or via automation). Unlabeled BM nodes fall through to `vm-worker` profile.

### Option B: Topology labels (auto-detected by OCP)

Use labels that OCP/vSphere/BM IPI already set:
- `node.openshift.io/os_id=rhcos` (all nodes)
- `beta.kubernetes.io/arch=amd64` (all nodes)
- VMware nodes may have `node.kubernetes.io/instance-type` set by vSphere CSI

Problem: There's no auto-detected label that distinguishes "enic BM" from "i40e BM" from "VMware VM" out of the box.

### Option C: MachineConfigPool-based (infrastructure already exists)

If the environment already has separate MCPs for BM workers vs VM workers:
```yaml
recommend:
  - machineConfigLabels:
      machineconfiguration.openshift.io/role: "baremetal-worker"
    priority: 10
    profile: baremetal-cisco-enic
```

---

## Priority Ordering Rationale

| Priority | Profile | Why this order |
|----------|---------|----------------|
| 10 | baremetal-cisco-enic | Most specific: enic-only settings (tcp_rmem 3MB workaround) |
| 11 | baremetal-cisco-i40e | Hardware-specific: i40e NIC settings |
| 12 | baremetal-dell-r6625 | Hardware-specific: bnxt_en settings |
| 15 | vm-control-plane | Role-specific: no THP change, ring buffers only |
| 16 | vm-infra | Role-specific: elevated somaxconn for routers |
| 20 | vm-worker | Catch-all: THP=never, ring buffers |

BM profiles have lowest priority numbers (highest precedence) because they have the most critical hardware-specific settings (tcp_rmem 3MB regression workaround). If a node somehow matches both BM and VM criteria, BM wins.

---

## Sequential Control-Plane Rollout (Label-Gating)

The `vm-control-plane` CR requires a gating label `tuning.custom/ring-resize=true` in addition to the role label. This enables safe one-at-a-time application:

```bash
# 1. Apply the CR (no nodes match yet)
oc apply -f manifests/vm-control-plane.yaml

# 2. Label first master → NTO applies profile to this node only
oc label node <master-0> tuning.custom/ring-resize=true

# 3. Verify etcd health
oc get etcd -o jsonpath='{.items[0].status.conditions[?(@.type=="EtcdMembersAvailable")].message}'

# 4. Wait 30s, then repeat for next master
oc label node <master-1> tuning.custom/ring-resize=true

# 5. After all masters stable: remove gating requirement from CR and re-apply
```

---

## Open Questions

- [ ] Which labeling strategy does the environment use? (A, B, or C)
- [ ] Are there already separate MCPs for BM vs VM workers?
