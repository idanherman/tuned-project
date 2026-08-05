# TuneD Optimization Project

Node Tuning Operator (NTO) optimization framework for OCP 4.16+ clusters — designed for air-gapped environments with mixed VMware and bare-metal hardware.

This repo provides ready-to-adapt Tuned CR manifests, per-parameter documentation, diagnostic scripts, and a monitoring stack. Fork it, fill in your cluster's details, and deploy.

## Directory Structure

```
tuned-project/
├── README.md
├── manifests/                          ← Deployable Tuned CR YAMLs (oc apply -f)
│   ├── vm-control-plane.yaml           ← With label-gating for sequential rollout
│   ├── vm-infra.yaml
│   ├── vm-worker.yaml
│   ├── baremetal-cisco-enic.yaml
│   ├── baremetal-cisco-i40e.yaml
│   └── baremetal-dell-r6625.yaml
├── docs/
│   ├── parameters/                     ← Per-parameter docs (grouped by TuneD section)
│   │   ├── sysctl/                     ← net.core.*, net.ipv4.*, fs.*, kernel.*, vm.*
│   │   ├── net/                        ← NIC hardware: ring, channels, coalesce, features
│   │   ├── vm/                         ← transparent_hugepages
│   │   └── cpu/                        ← C-states (boot params)
│   ├── labels-and-priorities/          ← NTO priority design, label strategy, rollout
│   └── packet-path/                    ← Educational: packet journey from wire to app
├── scripts/
│   ├── collect-nic-diagnostics.sh      ← Collect NIC health metrics (CSV + drop rates)
│   └── validate-tuning.sh             ← Post-apply validation (labels, profiles, sysctls)
├── monitoring/                         ← Grafana dashboard + custom Prometheus exporter
├── diagnostics/                        ← Collected data per cluster (gitignored)
└── references/                         ← Source material: KCS, cases, PS docs (gitignored)
```

## Getting Started

1. **Diagnose** — Run `scripts/collect-nic-diagnostics.sh` from bastion to capture baseline NIC health
2. **Document** — Fill in `docs/labels-and-priorities/current-state.md` with your cluster's baseline
3. **Adapt** — Modify manifests for your hardware (NIC drivers, node labels, sysctl values)
4. **Deploy** — Follow the rollout procedure below
5. **Validate** — Run `scripts/validate-tuning.sh` to confirm profiles applied correctly
6. **Monitor** — Deploy the Grafana dashboard and custom exporter from `monitoring/`

## Tracking Your Progress

Use a table like this to track tuning items for your engagement:

| Item | Status | Next step |
|------|--------|-----------|
| Ring buffers (vmxnet3) | *(investigate/ready/deployed)* | |
| tcp_rmem fix (enic only) | | See KCS 7127975 |
| netdev_max_backlog | | Raise if softnet_drops > 0 |
| somaxconn | | Review current value |
| THP | | `never` on workers, decide for masters |
| NIC-specific profile | | Match to your NIC driver |

## Deploy

```bash
# 1. Label bare-metal nodes by NIC driver
oc label node <bm-node> node.kubernetes.io/nic-driver=enic   # or i40e, bnxt_en

# 2. Apply manifests (workers first, then infra, then control-plane)
oc apply -f manifests/baremetal-cisco-enic.yaml
oc apply -f manifests/vm-worker.yaml
oc apply -f manifests/vm-infra.yaml
oc apply -f manifests/vm-control-plane.yaml

# 3. Sequential master rollout (one at a time, verify etcd health between each)
oc label node <master-0> tuning.custom/ring-resize=true
# verify etcd health, wait 30s, repeat for each master

# 4. Validate
./scripts/validate-tuning.sh
```

See `manifests/README.md` for detailed rollout procedure.

## Key Known Issues

**KCS 7127975 / RHEL-97545**: RHEL 9.4 has a TCP window auto-tuning regression affecting the **enic** driver specifically. Without setting `tcp_rmem` initial to 3MB, Cisco UCS nodes experience massive throughput degradation (image pulls taking hours). This affects OCP 4.16/4.17/4.18 on Cisco UCS blades.

The fix is in `manifests/baremetal-cisco-enic.yaml`. See `docs/parameters/sysctl/net.ipv4.tcp_rmem/` for full explanation and diagnosis steps.

## Design Principles

- **No MachineConfig / no reboots** — all tuning via NTO (TuneD) which applies live
- **Driver-specific profiles** — each NIC driver has different bugs, defaults, and capabilities
- **Sequential rollout** — label-gating on control-plane nodes to protect etcd quorum
- **Priority layering** — lower priority number = higher precedence; BM profiles (10-12) always win over VM profiles (15-20)
- **Traceable decisions** — every parameter links back to a KCS article or support case
