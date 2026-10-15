#!/bin/bash
# NUMA Topology & NIC DMA Diagnostics
# Run via: oc debug node/<node> -- chroot /host bash -c "$(cat collect-numa-diagnostics.sh)"
# Or copy to node and run as root

set -euo pipefail

echo "=========================================="
echo "NUMA & NIC DMA Diagnostics"
echo "Node: $(hostname)"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "=========================================="

echo ""
echo "=== 1. CPU & NUMA Topology ==="
echo ""

echo "--- lscpu summary ---"
lscpu | grep -E '(Socket|Core|Thread|NUMA|CPU\(s\)|Model name|Flags)'

echo ""
echo "--- NUMA node to CPU mapping ---"
for node_dir in /sys/devices/system/node/node[0-9]*; do
    node=$(basename "$node_dir")
    cpulist=$(cat "$node_dir/cpulist" 2>/dev/null || echo "N/A")
    meminfo=$(grep MemTotal "$node_dir/meminfo" 2>/dev/null | awk '{print $4, $5}' || echo "N/A")
    echo "$node: CPUs=$cpulist  Memory=$meminfo"
done

echo ""
echo "--- Hyperthread sibling pairs ---"
echo "(Physical core → Logical CPUs)"
for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*/topology; do
    cpu=$(basename "$(dirname "$cpu_dir")")
    core_id=$(cat "$cpu_dir/core_id" 2>/dev/null || echo "?")
    pkg_id=$(cat "$cpu_dir/physical_package_id" 2>/dev/null || echo "?")
    siblings=$(cat "$cpu_dir/thread_siblings_list" 2>/dev/null || echo "?")
    echo "  $cpu: socket=$pkg_id core=$core_id siblings=[$siblings]"
done | sort -t= -k2 -n | head -60

echo ""
echo "=== 2. NIC Inventory & NUMA Affinity ==="
echo ""

for iface in $(ls /sys/class/net/ | grep -v '^lo$'); do
    driver=$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "virtual")
    numa_node=$(cat "/sys/class/net/$iface/device/numa_node" 2>/dev/null || echo "N/A")
    pci_addr=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null | grep -oP '[0-9a-f]+:[0-9a-f]+:[0-9a-f]+\.[0-9a-f]+' || echo "N/A")
    operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "?")
    speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null || echo "?")
    mtu=$(cat "/sys/class/net/$iface/mtu" 2>/dev/null || echo "?")
    
    echo "--- $iface ---"
    echo "  Driver: $driver"
    echo "  PCI: $pci_addr"
    echo "  NUMA node: $numa_node"
    echo "  State: $operstate  Speed: ${speed}Mbps  MTU: $mtu"
    
    # RX/TX queue count
    rx_queues=$(ls -d /sys/class/net/$iface/queues/rx-* 2>/dev/null | wc -l)
    tx_queues=$(ls -d /sys/class/net/$iface/queues/tx-* 2>/dev/null | wc -l)
    echo "  Queues: RX=$rx_queues TX=$tx_queues"
    
    # Ring buffer sizes
    if command -v ethtool &>/dev/null; then
        echo "  Ring buffers:"
        ethtool -g "$iface" 2>/dev/null | grep -A2 "Current" | tail -2 | sed 's/^/    /'
    fi
    
    # RSS/aRFS capabilities
    if command -v ethtool &>/dev/null; then
        ntuple=$(ethtool -k "$iface" 2>/dev/null | grep ntuple | head -1 || echo "  ntuple: N/A")
        rxhash=$(ethtool -k "$iface" 2>/dev/null | grep receive-hashing | head -1 || echo "  receive-hashing: N/A")
        echo "  Features: $ntuple / $rxhash"
    fi
    
    echo ""
done

echo ""
echo "=== 3. IRQ to CPU Mapping (NIC queues) ==="
echo ""

for iface in $(ls /sys/class/net/ | grep -v '^lo$'); do
    driver=$(readlink -f "/sys/class/net/$iface/device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "virtual")
    [ "$driver" = "virtual" ] && continue
    
    echo "--- $iface ($driver) ---"
    # Find IRQs associated with this interface
    irq_count=0
    for irq_dir in /proc/irq/[0-9]*; do
        irq=$(basename "$irq_dir")
        affinity=$(cat "$irq_dir/smp_affinity_list" 2>/dev/null || continue)
        actions=$(cat "/proc/irq/$irq/actions" 2>/dev/null || cat "$irq_dir/spurious" 2>/dev/null || echo "")
        # Check if this IRQ belongs to our interface
        if grep -q "$iface" /proc/interrupts 2>/dev/null && grep "$iface" /proc/interrupts | grep -q "^[[:space:]]*$irq:"; then
            echo "  IRQ $irq → CPU(s) $affinity"
            irq_count=$((irq_count + 1))
        fi
    done
    
    # Simpler approach: parse /proc/interrupts
    if [ "$irq_count" -eq 0 ]; then
        grep "$iface" /proc/interrupts 2>/dev/null | while read line; do
            irq=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')
            name=$(echo "$line" | awk '{print $NF}')
            affinity=$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || echo "?")
            echo "  IRQ $irq ($name) → CPU(s) $affinity"
        done
    fi
    echo ""
done

echo ""
echo "=== 4. RFS/aRFS Configuration ==="
echo ""

echo "Global RFS flow entries: $(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo 'N/A')"
for iface in $(ls /sys/class/net/ | grep -v '^lo$'); do
    for rxq in /sys/class/net/$iface/queues/rx-*/rps_flow_cnt; do
        if [ -f "$rxq" ]; then
            val=$(cat "$rxq")
            [ "$val" != "0" ] && echo "  $rxq = $val"
        fi
    done 2>/dev/null
done

echo ""
echo "=== 5. NUMA Memory Distances ==="
echo ""

if [ -f /sys/devices/system/node/node0/distance ]; then
    echo "NUMA distance matrix:"
    for node_dir in /sys/devices/system/node/node[0-9]*; do
        node=$(basename "$node_dir")
        distances=$(cat "$node_dir/distance" 2>/dev/null || echo "N/A")
        echo "  $node: $distances"
    done
else
    echo "Single NUMA node (no distance matrix)"
fi

echo ""
echo "=== 6. Current softnet stats (per-CPU) ==="
echo ""

echo "CPU  processed  dropped  time_squeeze  cpu_collision  backlog_len"
cpu=0
while IFS= read -r line; do
    # Fields: processed dropped time_squeeze ... (hex)
    processed=$((16#$(echo "$line" | awk '{print $1}')))
    dropped=$((16#$(echo "$line" | awk '{print $2}')))
    squeeze=$((16#$(echo "$line" | awk '{print $3}')))
    collision=$((16#$(echo "$line" | awk '{print $4}')))
    backlog=$((16#$(echo "$line" | awk '{print $11}')))
    # Only show CPUs with non-zero activity
    if [ "$processed" -gt 0 ] || [ "$dropped" -gt 0 ] || [ "$squeeze" -gt 0 ]; then
        printf "%-4d %-10d %-8d %-13d %-14d %d\n" "$cpu" "$processed" "$dropped" "$squeeze" "$collision" "$backlog"
    fi
    cpu=$((cpu + 1))
done < /proc/net/softnet_stat

echo ""
echo "=== 7. DMA Allocation (IOMMU groups) ==="
echo ""

for iface in $(ls /sys/class/net/ | grep -v '^lo$'); do
    pci=$(readlink -f "/sys/class/net/$iface/device" 2>/dev/null | grep -oP '[0-9a-f]+:[0-9a-f]+:[0-9a-f]+\.[0-9a-f]+' || continue)
    iommu_group=$(readlink -f "/sys/class/net/$iface/device/iommu_group" 2>/dev/null | xargs basename 2>/dev/null || echo "N/A")
    echo "$iface ($pci): IOMMU group $iommu_group"
done

echo ""
echo "=== 8. cgroup version ==="
echo ""
if mount | grep -q "cgroup2"; then
    echo "cgroup v2 (unified)"
    mount | grep cgroup2 | head -1
else
    echo "cgroup v1 (legacy)"
    mount | grep cgroup | head -3
fi

echo ""
echo "=== 9. Current kubelet topology/CPU manager ==="
echo ""
if [ -f /etc/kubernetes/kubelet.conf ]; then
    grep -E '(topologyManager|cpuManager|systemReserved|podPidsLimit)' /etc/kubernetes/kubelet.conf 2>/dev/null || echo "No topology/cpu manager settings found in kubelet.conf"
elif [ -f /var/lib/kubelet/config.yaml ]; then
    grep -E '(topologyManager|cpuManager|systemReserved|podPidsLimit)' /var/lib/kubelet/config.yaml 2>/dev/null || echo "No topology/cpu manager settings found"
fi

echo ""
echo "=========================================="
echo "Collection complete"
echo "=========================================="
