# Load Test — Trigger NIC Drop Counters

Workload generators designed to stress specific parts of the network stack and trigger the drop counters monitored by the dashboard.

## Quick Start

```bash
# Deploy everything
oc apply -f monitoring/load-test/namespace.yaml
oc apply -f monitoring/load-test/servers.yaml

# Wait for servers to be ready
oc wait -n load-test pod/iperf3-server --for=condition=Ready --timeout=180s
oc wait -n load-test pod/http-server --for=condition=Ready --timeout=60s

# Run load generators
oc apply -f monitoring/load-test/generators.yaml

# Watch the dashboard light up, then clean up
oc delete namespace load-test
```

## What Each Generator Triggers

| Generator | Target counter | How it works |
|-----------|---------------|--------------|
| iperf3-flood (UDP small packets) | `ring_full`, `rx_no_bufs` | Floods tiny UDP packets faster than ring can drain |
| iperf3-multistream (TCP ×16) | `softnet_drops`, `squeezes` | 16 parallel TCP streams overwhelm per-CPU backlog |
| connection-flood (TCP SYN burst) | `ListenDrops`, `ListenOverflows` | Rapid connect/close cycles exhaust accept queue |
| http-flood (HTTP requests via route) | Router somaxconn, TCP retransmits | High request rate through HAProxy ingress |

## Expected Results on Default Config

With ring=1024/512 (vmxnet3 default, this lab):
- **iperf3-flood** at 10Gbps with 64-byte packets → millions of packets/sec → `ring_full` should increment
- **iperf3-multistream** with 16 streams → backlog pressure → `softnet_drops` if backlog=1000

After applying the TuneD profiles (ring=4096, backlog=5000):
- Same load → counters should stop growing (validates the fix)
