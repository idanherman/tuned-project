#!/bin/bash
#
# ethtool-collector.sh
# Textfile collector for node-exporter: exports ethtool -S driver-specific drop counters.
# Place output in /var/node_exporter/textfile/ethtool.prom
#
# Runs as a cron/timer on each node (every 30s or 60s).
# node-exporter reads .prom files from --collector.textfile.directory on each scrape.

set -euo pipefail

OUTFILE="/var/node_exporter/textfile/ethtool.prom"
TMPFILE="${OUTFILE}.tmp"

mkdir -p "$(dirname "$OUTFILE")"

: > "$TMPFILE"

for IFACE in $(ls /sys/class/net/); do
    [ ! -d "/sys/class/net/$IFACE" ] && continue
    [ "$(cat /sys/class/net/$IFACE/type 2>/dev/null)" != "1" ] && continue

    DRIVER=$(ethtool -i "$IFACE" 2>/dev/null | awk '/^driver:/{print $2}')
    [ -z "$DRIVER" ] && continue
    case "$DRIVER" in bridge|openvswitch|veth|tun|geneve|vxlan) continue;; esac

    STATS=$(ethtool -S "$IFACE" 2>/dev/null)
    [ -z "$STATS" ] && continue

    case "$DRIVER" in
        vmxnet3)
            RING_FULL=$(echo "$STATS" | grep 'ring full:' | awk '{sum+=$3} END{print sum+0}')
            OOB=$(echo "$STATS" | grep 'pkts rx OOB:' | awk '{sum+=$4} END{print sum+0}')
            DRV_DROP_TX=$(echo "$STATS" | grep 'drv dropped tx total:' | awk '{sum+=$5} END{print sum+0}')
            DRV_DROP_RX=$(echo "$STATS" | grep 'drv dropped rx total:' | awk '{sum+=$5} END{print sum+0}')

            echo "node_ethtool_ring_full_total{device=\"$IFACE\",driver=\"$DRIVER\"} $RING_FULL" >> "$TMPFILE"
            echo "node_ethtool_rx_out_of_buffer_total{device=\"$IFACE\",driver=\"$DRIVER\"} $OOB" >> "$TMPFILE"
            echo "node_ethtool_drv_dropped_tx_total{device=\"$IFACE\",driver=\"$DRIVER\"} $DRV_DROP_TX" >> "$TMPFILE"
            echo "node_ethtool_drv_dropped_rx_total{device=\"$IFACE\",driver=\"$DRIVER\"} $DRV_DROP_RX" >> "$TMPFILE"
            ;;
        enic)
            RX_NO_BUFS=$(echo "$STATS" | grep -m1 'rx_no_bufs:' | awk '{print $2+0}')
            RX_DROP=$(echo "$STATS" | grep -m1 'rx_drop:' | awk '{print $2+0}')
            TX_DROP=$(echo "$STATS" | grep -m1 'tx_drop:' | awk '{print $2+0}')

            echo "node_ethtool_rx_no_bufs_total{device=\"$IFACE\",driver=\"$DRIVER\"} $RX_NO_BUFS" >> "$TMPFILE"
            echo "node_ethtool_rx_drop_total{device=\"$IFACE\",driver=\"$DRIVER\"} $RX_DROP" >> "$TMPFILE"
            echo "node_ethtool_tx_drop_total{device=\"$IFACE\",driver=\"$DRIVER\"} $TX_DROP" >> "$TMPFILE"
            ;;
        i40e)
            RX_DROPPED=$(echo "$STATS" | grep -m1 'rx_dropped:' | awk '{print $2+0}')
            RX_MISSED=$(echo "$STATS" | grep -m1 'rx_missed_errors:' | awk '{print $2+0}')
            TX_DROPPED=$(echo "$STATS" | grep -m1 'tx_dropped:' | awk '{print $2+0}')
            TX_RESTART=$(echo "$STATS" | grep 'tx_restart:' | awk '{sum+=$2} END{print sum+0}')

            echo "node_ethtool_rx_dropped_total{device=\"$IFACE\",driver=\"$DRIVER\"} $RX_DROPPED" >> "$TMPFILE"
            echo "node_ethtool_rx_missed_total{device=\"$IFACE\",driver=\"$DRIVER\"} $RX_MISSED" >> "$TMPFILE"
            echo "node_ethtool_tx_dropped_total{device=\"$IFACE\",driver=\"$DRIVER\"} $TX_DROPPED" >> "$TMPFILE"
            echo "node_ethtool_tx_restart_total{device=\"$IFACE\",driver=\"$DRIVER\"} $TX_RESTART" >> "$TMPFILE"
            ;;
        bnxt_en)
            RX_DISCARD=$(echo "$STATS" | grep -m1 'rx_discard_pkts:' | awk '{print $2+0}')
            RX_ERROR=$(echo "$STATS" | grep -m1 'rx_error_pkts:' | awk '{print $2+0}')
            TX_DISCARD=$(echo "$STATS" | grep -m1 'tx_discard_pkts:' | awk '{print $2+0}')

            echo "node_ethtool_rx_discard_total{device=\"$IFACE\",driver=\"$DRIVER\"} $RX_DISCARD" >> "$TMPFILE"
            echo "node_ethtool_rx_error_total{device=\"$IFACE\",driver=\"$DRIVER\"} $RX_ERROR" >> "$TMPFILE"
            echo "node_ethtool_tx_discard_total{device=\"$IFACE\",driver=\"$DRIVER\"} $TX_DISCARD" >> "$TMPFILE"
            ;;
    esac

    # Ring buffer utilization (all drivers)
    RING_INFO=$(ethtool -g "$IFACE" 2>/dev/null)
    if [ -n "$RING_INFO" ]; then
        RX_MAX=$(echo "$RING_INFO" | awk '/Pre-set maximums:/{f=1} f && /^RX:/{print $2; exit}')
        RX_CUR=$(echo "$RING_INFO" | awk '/Current hardware settings:/{f=1} f && /^RX:/{print $2; exit}')
        TX_MAX=$(echo "$RING_INFO" | awk '/Pre-set maximums:/{f=1} f && /^TX:/{print $2; exit}')
        TX_CUR=$(echo "$RING_INFO" | awk '/Current hardware settings:/{f=1} f && /^TX:/{print $2; exit}')

        [ -n "$RX_MAX" ] && echo "node_ethtool_ring_rx_max{device=\"$IFACE\",driver=\"$DRIVER\"} $RX_MAX" >> "$TMPFILE"
        [ -n "$RX_CUR" ] && echo "node_ethtool_ring_rx_current{device=\"$IFACE\",driver=\"$DRIVER\"} $RX_CUR" >> "$TMPFILE"
        [ -n "$TX_MAX" ] && echo "node_ethtool_ring_tx_max{device=\"$IFACE\",driver=\"$DRIVER\"} $TX_MAX" >> "$TMPFILE"
        [ -n "$TX_CUR" ] && echo "node_ethtool_ring_tx_current{device=\"$IFACE\",driver=\"$DRIVER\"} $TX_CUR" >> "$TMPFILE"
    fi
done

# Atomic rename to avoid partial reads by node-exporter
mv "$TMPFILE" "$OUTFILE"
