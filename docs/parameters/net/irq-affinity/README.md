# irq-affinity — IRQ Pinning

## Status: Future

IRQ affinity controls which CPUs handle hardware interrupts from the NIC. Pinning IRQs to specific cores can reduce cache thrashing and improve throughput.

## Current state

`irqbalance` is running on all nodes and distributing NIC interrupts across available CPUs. Under current workloads, this produces acceptable interrupt distribution without manual pinning.

## Why postponed

1. **Primary fixes address main symptoms** — ring buffer, backlog, and tcp_rmem changes resolve drops and throughput issues first
2. **PerformanceProfile dependency** — proper IRQ affinity on OpenShift typically requires a PerformanceProfile CR, which is a heavier operational change (reserved CPUs, kernel arguments, node reboot)
3. **irqbalance is adequate** — no evidence of concentrated per-CPU `softnet_drops` that would indicate a pinning problem

## When to revisit

Re-examine IRQ affinity if, after deploying the primary network fixes:
- `softnet_drops` are concentrated on specific CPUs (check `/proc/net/softnet_stat` per-CPU columns)
- `ethtool -S <iface>` shows uneven per-queue rx counts despite multi-queue being enabled
- Latency-sensitive workloads show jitter correlated with interrupt migration

## How it would be configured

Via PerformanceProfile (not TuneD):

```yaml
apiVersion: performance.openshift.io/v2
kind: PerformanceProfile
spec:
  cpu:
    isolated: "2-15"
    reserved: "0-1"
  net:
    devices:
      - interfaceName: "ens*"
    userLevelNetworking: true
```

Or manually via TuneD's `[script]` section writing to `/proc/irq/<N>/smp_affinity_list`.
