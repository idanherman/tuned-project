#!/bin/bash
#
# collect-nic-diagnostics.sh
# Run from bastion with oc access. Collects per-node NIC health metrics via oc debug.
# Outputs CSV with one row per node/interface.
#
# Usage: ./collect-nic-diagnostics.sh

set -euo pipefail

TIMEOUT=120
OUTFILE="nic-diagnostics-$(date +%Y%m%d-%H%M%S).csv"

header="node,role,platform,driver,interface,ring_rx_cur,ring_rx_max,ring_tx_cur,ring_tx_max,queues_combined,rx_drops,tx_drops,rx_errors,driver_specific_drops,softnet_drops_total,softnet_squeeze_total,netdev_budget,netdev_max_backlog,netdev_budget_usecs,wmem_max,rmem_max,tcp_rmem,tcp_wmem,somaxconn,uptime_secs,thp_state,tuned_profile"
echo "$header" > "$OUTFILE"

NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')

NODE_COUNT=$(echo "$NODES" | wc -w | tr -d ' ')
echo "Collecting NIC diagnostics from $NODE_COUNT nodes..."
echo "Output: $OUTFILE"
echo ""

CURRENT=0
for NODE in $NODES; do
    CURRENT=$((CURRENT + 1))

    NODE_ROLES=$(oc get node "$NODE" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -oP 'node-role.kubernetes.io/\K[^"]*' | tr '\n' '+' | sed 's/+$//')
    [ -z "$NODE_ROLES" ] && NODE_ROLES="worker"

    echo "[$CURRENT/$NODE_COUNT] $NODE ($NODE_ROLES) ..."

    COLLECT_SCRIPT="
NODE_NAME=\"$NODE\"

PLATFORM=\$(systemd-detect-virt 2>/dev/null || true)
PLATFORM=\${PLATFORM:-unknown}
[ \"\$PLATFORM\" = \"none\" ] && PLATFORM=\"bare-metal\"

TUNED_PROFILE=\$(cat /var/lib/ocp-tuned/recommend.d/50-openshift.conf 2>/dev/null | grep -oP '^\[\K[^\]]+' || echo 'unknown')

NETDEV_BUDGET=\$(sysctl -n net.core.netdev_budget 2>/dev/null || echo 'N/A')
NETDEV_BACKLOG=\$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 'N/A')
NETDEV_BUDGET_USECS=\$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo 'N/A')
WMEM_MAX=\$(sysctl -n net.core.wmem_max 2>/dev/null || echo 'N/A')
RMEM_MAX=\$(sysctl -n net.core.rmem_max 2>/dev/null || echo 'N/A')
TCP_RMEM=\$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | tr '\t' ' ' || echo 'N/A')
TCP_WMEM=\$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | tr '\t' ' ' || echo 'N/A')
SOMAXCONN=\$(sysctl -n net.core.somaxconn 2>/dev/null || echo 'N/A')
UPTIME_SECS=\$(awk '{print int(\$1)}' /proc/uptime 2>/dev/null || echo '0')
THP_STATE=\$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K[^\]]+' || echo 'unknown')

SOFTNET_DROPS=\$(awk '{sum += strtonum(\"0x\"\$2)} END {print sum+0}' /proc/net/softnet_stat 2>/dev/null || echo '0')
SOFTNET_SQUEEZE=\$(awk '{sum += strtonum(\"0x\"\$3)} END {print sum+0}' /proc/net/softnet_stat 2>/dev/null || echo '0')

for IFACE in \$(ls /sys/class/net/ | grep -vE '^(lo|veth|br-|ovs|tun|genev|flannel|cali|cni|dummy)'); do
    [ ! -d \"/sys/class/net/\$IFACE\" ] && continue
    [ \"\$(cat /sys/class/net/\$IFACE/type 2>/dev/null)\" != \"1\" ] && continue

    DRIVER=\$(ethtool -i \"\$IFACE\" 2>/dev/null | awk '/^driver:/{print \$2}')
    [ -z \"\$DRIVER\" ] && continue
    case \"\$DRIVER\" in bridge|openvswitch|veth|tun|geneve|vxlan) continue;; esac

    RING_INFO=\$(ethtool -g \"\$IFACE\" 2>/dev/null)
    RING_RX_MAX=\$(echo \"\$RING_INFO\" | awk '/Pre-set maximums:/{found=1} found && /^RX:/{print \$2; exit}')
    RING_TX_MAX=\$(echo \"\$RING_INFO\" | awk '/Pre-set maximums:/{found=1} found && /^TX:/{print \$2; exit}')
    RING_RX_CUR=\$(echo \"\$RING_INFO\" | awk '/Current hardware settings:/{found=1} found && /^RX:/{print \$2; exit}')
    RING_TX_CUR=\$(echo \"\$RING_INFO\" | awk '/Current hardware settings:/{found=1} found && /^TX:/{print \$2; exit}')
    : \${RING_RX_MAX:=N/A} \${RING_TX_MAX:=N/A} \${RING_RX_CUR:=N/A} \${RING_TX_CUR:=N/A}

    CHAN_INFO=\$(ethtool -l \"\$IFACE\" 2>/dev/null)
    QUEUES_COMBINED=\$(echo \"\$CHAN_INFO\" | awk '/Current hardware settings:/{found=1} found && /^Combined:/{print \$2; exit}')
    : \${QUEUES_COMBINED:=N/A}

    RX_LINE=\$(ip -s link show \"\$IFACE\" 2>/dev/null | grep -A2 '^ *RX:' | tail -1)
    TX_LINE=\$(ip -s link show \"\$IFACE\" 2>/dev/null | grep -A2 '^ *TX:' | tail -1)
    RX_ERRORS=\$(echo \"\$RX_LINE\" | awk '{print \$3+0}')
    RX_DROPS=\$(echo \"\$RX_LINE\" | awk '{print \$4+0}')
    TX_DROPS=\$(echo \"\$TX_LINE\" | awk '{print \$4+0}')
    : \${RX_ERRORS:=0} \${RX_DROPS:=0} \${TX_DROPS:=0}

    ETHTOOL_S=\$(ethtool -S \"\$IFACE\" 2>/dev/null)
    DRIVER_DROPS=\"\"
    case \"\$DRIVER\" in
        enic)
            NO_BUFS=\$(echo \"\$ETHTOOL_S\" | grep -m1 'rx_no_bufs:' | awk '{print \$2}')
            RX_DROP_D=\$(echo \"\$ETHTOOL_S\" | grep -m1 'rx_drop:' | awk '{print \$2}')
            DRIVER_DROPS=\"rx_no_bufs=\${NO_BUFS:-0};rx_drop=\${RX_DROP_D:-0}\"
            ;;
        vmxnet3)
            RING_FULL=\$(echo \"\$ETHTOOL_S\" | grep 'ring full:' | awk '{sum+=\$3} END{print sum+0}')
            OOB=\$(echo \"\$ETHTOOL_S\" | grep 'pkts rx OOB:' | awk '{sum+=\$4} END{print sum+0}')
            DRIVER_DROPS=\"ring_full=\${RING_FULL:-0};pkts_rx_OOB=\${OOB:-0}\"
            ;;
        i40e)
            RX_DROPPED=\$(echo \"\$ETHTOOL_S\" | grep -m1 'rx_dropped:' | awk '{print \$2}')
            RX_MISSED=\$(echo \"\$ETHTOOL_S\" | grep -m1 'rx_missed_errors:' | awk '{print \$2}')
            DRIVER_DROPS=\"rx_dropped=\${RX_DROPPED:-0};rx_missed=\${RX_MISSED:-0}\"
            ;;
        bnxt_en)
            RX_DISCARD=\$(echo \"\$ETHTOOL_S\" | grep -m1 'rx_discard_pkts:' | awk '{print \$2}')
            RX_ERR_D=\$(echo \"\$ETHTOOL_S\" | grep -m1 'rx_error_pkts:' | awk '{print \$2}')
            DRIVER_DROPS=\"rx_discard=\${RX_DISCARD:-0};rx_error=\${RX_ERR_D:-0}\"
            ;;
        *)
            RX_D_GENERIC=\$(echo \"\$ETHTOOL_S\" | grep -iE 'drop|discard|miss|no_buf' | head -3 | tr '\n' ';' | sed 's/ *//g')
            DRIVER_DROPS=\"\${RX_D_GENERIC:-none}\"
            ;;
    esac

    echo \"\${NODE_NAME},${NODE_ROLES},\${PLATFORM},\${DRIVER},\${IFACE},\${RING_RX_CUR},\${RING_RX_MAX},\${RING_TX_CUR},\${RING_TX_MAX},\${QUEUES_COMBINED},\${RX_DROPS},\${TX_DROPS},\${RX_ERRORS},\${DRIVER_DROPS},\${SOFTNET_DROPS},\${SOFTNET_SQUEEZE},\${NETDEV_BUDGET},\${NETDEV_BACKLOG},\${NETDEV_BUDGET_USECS},\${WMEM_MAX},\${RMEM_MAX},\${TCP_RMEM},\${TCP_WMEM},\${SOMAXCONN},\${UPTIME_SECS},\${THP_STATE},\${TUNED_PROFILE}\"
done
"

    RAW_OUTPUT=$(timeout "$TIMEOUT" oc debug "node/$NODE" -- chroot /host bash -c "$COLLECT_SCRIPT" 2>/dev/null | grep -v "^Starting\|^Removing\|^Temporary\|^$" || echo "$NODE,$NODE_ROLES,error,timeout,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-,-")

    while IFS= read -r line; do
        [ -n "$line" ] && echo "$line" >> "$OUTFILE"
    done <<< "$RAW_OUTPUT"
done

echo ""
echo "=== Collection complete: $OUTFILE ==="
echo ""

echo "--- Summary: nodes with non-zero drops/errors ---"
echo ""
{
    head -1 "$OUTFILE"
    tail -n +2 "$OUTFILE" | awk -F',' '
        $11+0 > 0 || $12+0 > 0 || $13+0 > 0 || $15+0 > 0 {print}
    '
} | column -t -s',' 2>/dev/null || {
    head -1 "$OUTFILE"
    tail -n +2 "$OUTFILE" | awk -F',' '$11+0 > 0 || $12+0 > 0 || $13+0 > 0 || $15+0 > 0'
}

echo ""
echo "--- Drop rate estimates (drops/hour based on uptime) ---"
echo ""
{
    echo "node,softnet_drops,uptime_hours,drops_per_hour,severity"
    tail -n +2 "$OUTFILE" | awk -F',' '$15+0 > 0 && $25+0 > 0 {
        uptime_hrs = $25 / 3600
        rate = $15 / uptime_hrs
        severity = "OK"
        if (rate > 1000) severity = "HIGH"
        else if (rate > 100) severity = "MODERATE"
        printf "%s,%.0f,%.1f,%.1f,%s\n", $1, $15+0, uptime_hrs, rate, severity
    }'
} | column -t -s',' 2>/dev/null || cat

echo ""
echo "--- Ring buffer utilization (current vs max) ---"
echo ""
{
    echo "node,interface,driver,ring_rx_cur/max,ring_tx_cur/max,status"
    tail -n +2 "$OUTFILE" | awk -F',' '{
        rx_status = ($6+0 < $7+0) ? "BELOW_MAX" : "AT_MAX"
        tx_status = ($8+0 < $9+0) ? "BELOW_MAX" : "AT_MAX"
        status = (rx_status == "BELOW_MAX" || tx_status == "BELOW_MAX") ? "NEEDS_INCREASE" : "OK"
        printf "%s,%s,%s,%s/%s,%s/%s,%s\n", $1, $5, $4, $6, $7, $8, $9, status
    }'
} | column -t -s',' 2>/dev/null || cat

TOTAL_ISSUES=$(tail -n +2 "$OUTFILE" | awk -F',' '$11+0 > 0 || $12+0 > 0 || $13+0 > 0 || $15+0 > 0' | wc -l | tr -d ' ')
RING_ISSUES=$(tail -n +2 "$OUTFILE" | awk -F',' '$6+0 > 0 && $7+0 > 0 && $6+0 < $7+0' | wc -l | tr -d ' ')
echo ""
echo "Total interfaces with drops/errors: $TOTAL_ISSUES"
echo "Total interfaces with ring buffers below max: $RING_ISSUES"
echo "Full CSV: $OUTFILE"
