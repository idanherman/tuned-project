# Monitoring

Grafana dashboard and metric collection for NIC health and tuning validation.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Node (RHCOS)                                               │
│                                                             │
│  Platform node-exporter (built-in)                          │
│  ├── node_softnet_*                    ← backlog / NAPI     │
│  ├── node_network_*                    ← iface drops/errs   │
│  ├── node_netstat_Tcp*                 ← TCP / listen       │
│  └── node_nf_conntrack_*               ← conntrack          │
│                                                             │
│  Custom node-exporter (ConfigMap commands)                  │
│  ├── nic_enic_rx_buffer / nic_vmxnet3_rx_buffer             │
│  ├── nic_enic_rx_drop / nic_vmxnet3_rx_drop                 │
│  ├── nic_enic_tx_drop / nic_vmxnet3_tx_drop                 │
│  └── nic_ring_{rx,tx}_{current,max}                         │
└─────────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────┐      ┌──────────────────────┐
│  Prometheus / thanos        │─────▶│  Grafana             │
│                             │      │  NIC Health Dashboard │
└─────────────────────────────┘      └──────────────────────┘
```

On OCP 4.16 the platform `ethtool` collector is **not** officially configurable (needs 4.22+). Do **not** use MachineConfig for this if workloads are not reboot-tolerant. Use the command-driven exporter + ConfigMap approach instead.

## Components

| File | Purpose |
|------|---------|
| [dashboard.json](dashboard.json) | Grafana dashboard (uses `nic_*` + platform metrics) |
| [custom-exporter-metrics.conf](custom-exporter-metrics.conf) | Lines to merge into their metrics ConfigMap |
| [custom-exporter-metrics-configmap.yaml](custom-exporter-metrics-configmap.yaml) | Example ConfigMap wrapper |
| [ethtool-collector.sh](ethtool-collector.sh) | **Legacy** textfile/MachineConfig approach — do not use |

## Custom exporter metrics

Format: `interval_sec,metric_name,command,is_string` (`False` = float).

| Metric | Source | Use |
|--------|--------|-----|
| `nic_enic_rx_buffer` | enic `rx_no_bufs` | enic **RX buffer** exhaustion |
| `nic_vmxnet3_rx_buffer` | vmxnet3 `pkts rx OOB` | vmxnet3 **RX buffer** exhaustion |
| `nic_enic_rx_drop` | enic `rx_drop` | enic regular **RX drop** |
| `nic_vmxnet3_rx_drop` | vmxnet3 `drv dropped rx total` | vmxnet3 regular **RX drop** |
| `nic_enic_tx_drop` | enic `tx_drop` | enic **TX drop** (no `tx_no_bufs`) |
| `nic_vmxnet3_tx_drop` | vmxnet3 `ring full` | vmxnet3 **TX** ring overflow (main signal) |
| `nic_ring_rx_current` / `_max` | `ethtool -g` | Prove ring resize applied (want ~100%) |
| `nic_ring_tx_current` / `_max` | `ethtool -g` | Same for TX |

Commands auto-discover the first matching NIC (no hardcoded `ens192`). On non-matching drivers they print `0`.

## Platform metrics (no ConfigMap needed)

- `node_softnet_dropped_total` / `node_softnet_times_squeezed_total`
- `node_network_receive_drop_total` / `_errs_total` / transmit drops
- `node_netstat_Tcp_RetransSegs`, `TCPTimeouts`, `ListenDrops`, `ListenOverflows`
- Throughput: `node_network_*_packets_total` / `_bytes_total`
- Conntrack: `node_nf_conntrack_entries` / `_limit` / `stat_drop`

## Dashboard rows

1. **NIC Hardware Drops** — 6 columns: RX buffer / RX drop / TX drop × enic | vmxnet3 (`ethtool -S`)
2. **Ring Buffer Config** — current/max % (green ≈ 100% after TuneD)
3. **Kernel Backlog** — softnet
4. **Kernel netdev (`ip -s link`)** — `node_network_*` RX/TX dropped + RX errors (**not** the same as ethtool)
5. **TCP Health** — retrans / timeouts / listen
6. **Throughput** — context
7. **Conntrack** — pressure (already high max from openshift parent on lab)
8. **Thermal** — BM only

### Drop layers (do not expect numbers to match)

```text
wire → ethtool -S (nic_*) → driver → ip -s link (node_network_*) → softnet → TCP
```

| Layer | Where on dashboard | Source |
|-------|--------------------|--------|
| NIC / driver | Row 1 `nic_*` | `ethtool -S` via custom exporter |
| Kernel netdev | Row 4 `node_network_*` | ≈ `ip -s link` via platform node-exporter |
| Softnet backlog | Row 3 | `/proc/net/softnet_stat` |

## Before / after a TuneD change

Watch **rates**, not boot-lifetime totals:

- Ring raise → `rate(nic_ring_full[5m])` stops growing; ring % → 100
- Backlog raise → `rate(node_softnet_dropped_total[5m])` → ~0
- Infra somaxconn → ListenDrops rate stays flat under load
