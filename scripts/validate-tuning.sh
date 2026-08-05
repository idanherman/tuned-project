#!/bin/bash
#
# validate-tuning.sh
# Validates that TuneD profiles are correctly applied across all nodes.
# Checks active profile, critical sysctls, ring buffers, and labeling.
#
# Usage: ./validate-tuning.sh
#
# Exit codes:
#   0 = all checks passed
#   1 = one or more checks failed (see output)

set -euo pipefail

TIMEOUT=60
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'
FAILURES=0

pass() { echo -e "  ${GREEN}PASS${NC} $1"; }
fail() { echo -e "  ${RED}FAIL${NC} $1"; FAILURES=$((FAILURES + 1)); }
warn() { echo -e "  ${YELLOW}WARN${NC} $1"; }
info() { echo -e "  ---- $1"; }

echo "============================================"
echo " TuneD Profile Validation"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "============================================"
echo ""

# --- Pre-flight: check labeling ---
echo "=== Phase 1: Node Label Verification ==="
echo ""

BM_NODES_UNLABELED=0
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}')

for NODE in $WORKER_NODES; do
    NIC_LABEL=$(oc get node "$NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/nic-driver}' 2>/dev/null || true)
    PLATFORM=$(oc debug "node/$NODE" --quiet -- chroot /host systemd-detect-virt 2>/dev/null | grep -v "^$" || echo "unknown")

    if [[ "$PLATFORM" == "none" || "$PLATFORM" == "bare-metal" ]] && [[ -z "$NIC_LABEL" ]]; then
        fail "$NODE: bare-metal node missing 'node.kubernetes.io/nic-driver' label"
        BM_NODES_UNLABELED=$((BM_NODES_UNLABELED + 1))
    elif [[ -n "$NIC_LABEL" ]]; then
        pass "$NODE: labeled nic-driver=$NIC_LABEL"
    fi
done

if [[ $BM_NODES_UNLABELED -gt 0 ]]; then
    warn "  $BM_NODES_UNLABELED bare-metal nodes are unlabeled — they will get the vm-worker profile (WRONG)"
fi
echo ""

# --- Phase 2: Profile assignment ---
echo "=== Phase 2: Active TuneD Profile Verification ==="
echo ""

NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')

for NODE in $NODES; do
    ROLES=$(oc get node "$NODE" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -oP 'node-role.kubernetes.io/\K[^"]*' | tr '\n' '+' | sed 's/+$//')
    NIC_LABEL=$(oc get node "$NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/nic-driver}' 2>/dev/null || true)

    # Determine expected profile
    EXPECTED=""
    if [[ -n "$NIC_LABEL" ]]; then
        case "$NIC_LABEL" in
            enic)    EXPECTED="baremetal-cisco-enic" ;;
            i40e)    EXPECTED="baremetal-cisco-i40e" ;;
            bnxt_en) EXPECTED="baremetal-dell-r6625" ;;
        esac
    elif echo "$ROLES" | grep -q "control-plane\|master"; then
        EXPECTED="vm-control-plane"
    elif echo "$ROLES" | grep -q "infra"; then
        EXPECTED="vm-infra"
    elif echo "$ROLES" | grep -q "worker"; then
        EXPECTED="vm-worker"
    fi

    ACTUAL=$(timeout "$TIMEOUT" oc debug "node/$NODE" --quiet -- chroot /host bash -c \
        "tuned-adm active 2>/dev/null | awk -F': ' '{print \$2}'" 2>/dev/null | grep -v "^$" || echo "unknown")

    if [[ "$ACTUAL" == "$EXPECTED" ]]; then
        pass "$NODE ($ROLES): profile=$ACTUAL"
    elif [[ -z "$EXPECTED" ]]; then
        info "$NODE ($ROLES): profile=$ACTUAL (no expected profile defined)"
    else
        fail "$NODE ($ROLES): expected=$EXPECTED, actual=$ACTUAL"
    fi
done
echo ""

# --- Phase 3: Critical sysctl validation ---
echo "=== Phase 3: Critical Sysctl Validation ==="
echo ""

validate_node_sysctls() {
    local NODE="$1"
    local ROLE="$2"
    local NIC_DRIVER="$3"

    local CHECK_SCRIPT="
RESULTS=''

TCP_RMEM=\$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null | awk '{print \$2}')
SOMAXCONN=\$(sysctl -n net.core.somaxconn 2>/dev/null)
BACKLOG=\$(sysctl -n net.core.netdev_max_backlog 2>/dev/null)
THP=\$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | grep -oP '\[\K[^\]]+')
BUDGET_USECS=\$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null)

echo \"tcp_rmem_initial=\${TCP_RMEM}\"
echo \"somaxconn=\${SOMAXCONN}\"
echo \"backlog=\${BACKLOG}\"
echo \"thp=\${THP}\"
echo \"budget_usecs=\${BUDGET_USECS}\"
"

    local OUTPUT
    OUTPUT=$(timeout "$TIMEOUT" oc debug "node/$NODE" --quiet -- chroot /host bash -c "$CHECK_SCRIPT" 2>/dev/null | grep -v "^$" || echo "error=true")

    local TCP_RMEM_INIT SOMAXCONN BACKLOG THP BUDGET_USECS
    TCP_RMEM_INIT=$(echo "$OUTPUT" | grep "tcp_rmem_initial=" | cut -d= -f2)
    SOMAXCONN=$(echo "$OUTPUT" | grep "somaxconn=" | cut -d= -f2)
    BACKLOG=$(echo "$OUTPUT" | grep "backlog=" | cut -d= -f2)
    THP=$(echo "$OUTPUT" | grep "thp=" | cut -d= -f2)
    BUDGET_USECS=$(echo "$OUTPUT" | grep "budget_usecs=" | cut -d= -f2)

    # Validate based on role/driver
    case "$NIC_DRIVER" in
        enic)
            [[ "$TCP_RMEM_INIT" == "3145728" ]] && pass "$NODE: tcp_rmem initial=3MB (enic fix)" || fail "$NODE: tcp_rmem initial=$TCP_RMEM_INIT (expected 3145728)"
            [[ "$BACKLOG" == "5000" ]] && pass "$NODE: netdev_max_backlog=5000" || fail "$NODE: netdev_max_backlog=$BACKLOG (expected 5000)"
            [[ "$THP" == "never" ]] && pass "$NODE: THP=never" || fail "$NODE: THP=$THP (expected never)"
            [[ "$BUDGET_USECS" == "4000" ]] && pass "$NODE: netdev_budget_usecs=4000" || warn "$NODE: netdev_budget_usecs=$BUDGET_USECS (expected 4000)"
            ;;
        i40e|bnxt_en)
            [[ "$BACKLOG" == "5000" ]] && pass "$NODE: netdev_max_backlog=5000" || fail "$NODE: netdev_max_backlog=$BACKLOG (expected 5000)"
            [[ "$THP" == "never" ]] && pass "$NODE: THP=never" || fail "$NODE: THP=$THP (expected never)"
            [[ "$BUDGET_USECS" == "4000" ]] && pass "$NODE: netdev_budget_usecs=4000" || warn "$NODE: netdev_budget_usecs=$BUDGET_USECS (expected 4000)"
            ;;
        *)
            if echo "$ROLE" | grep -q "infra"; then
                [[ "$SOMAXCONN" == "10240" ]] && pass "$NODE: somaxconn=10240 (infra)" || fail "$NODE: somaxconn=$SOMAXCONN (expected 10240)"
            elif echo "$ROLE" | grep -q "worker"; then
                [[ "$THP" == "never" ]] && pass "$NODE: THP=never (worker)" || fail "$NODE: THP=$THP (expected never)"
                [[ "$SOMAXCONN" != "655535" ]] && pass "$NODE: somaxconn=$SOMAXCONN (not legacy 655535)" || fail "$NODE: somaxconn=655535 (LEGACY — must remove)"
            elif echo "$ROLE" | grep -q "control-plane\|master"; then
                [[ "$THP" == "always" ]] && pass "$NODE: THP=always (control-plane)" || warn "$NODE: THP=$THP (expected always on CP)"
            fi
            ;;
    esac
}

for NODE in $NODES; do
    ROLES=$(oc get node "$NODE" -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -oP 'node-role.kubernetes.io/\K[^"]*' | tr '\n' '+' | sed 's/+$//')
    NIC_LABEL=$(oc get node "$NODE" -o jsonpath='{.metadata.labels.node\.kubernetes\.io/nic-driver}' 2>/dev/null || true)
    validate_node_sysctls "$NODE" "$ROLES" "$NIC_LABEL"
done
echo ""

# --- Phase 4: Ring buffer validation ---
echo "=== Phase 4: Ring Buffer Validation ==="
echo ""

for NODE in $NODES; do
    RING_CHECK=$(timeout "$TIMEOUT" oc debug "node/$NODE" --quiet -- chroot /host bash -c "
for IFACE in \$(ls /sys/class/net/ | grep -vE '^(lo|veth|br-|ovs|tun|genev|flannel|cali|cni|dummy)'); do
    [ ! -d /sys/class/net/\$IFACE ] && continue
    [ \"\$(cat /sys/class/net/\$IFACE/type 2>/dev/null)\" != \"1\" ] && continue
    DRIVER=\$(ethtool -i \$IFACE 2>/dev/null | awk '/^driver:/{print \$2}')
    case \"\$DRIVER\" in bridge|openvswitch|veth|tun|geneve|vxlan) continue;; esac
    [ -z \"\$DRIVER\" ] && continue
    RING=\$(ethtool -g \$IFACE 2>/dev/null)
    RX_CUR=\$(echo \"\$RING\" | awk '/Current hardware settings:/{f=1} f && /^RX:/{print \$2; exit}')
    TX_CUR=\$(echo \"\$RING\" | awk '/Current hardware settings:/{f=1} f && /^TX:/{print \$2; exit}')
    RX_MAX=\$(echo \"\$RING\" | awk '/Pre-set maximums:/{f=1} f && /^RX:/{print \$2; exit}')
    TX_MAX=\$(echo \"\$RING\" | awk '/Pre-set maximums:/{f=1} f && /^TX:/{print \$2; exit}')
    echo \"\$IFACE|\$DRIVER|\$RX_CUR|\$RX_MAX|\$TX_CUR|\$TX_MAX\"
done
" 2>/dev/null | grep -v "^$" || echo "error|error|0|0|0|0")

    while IFS='|' read -r IFACE DRIVER RX_CUR RX_MAX TX_CUR TX_MAX; do
        [[ -z "$IFACE" || "$IFACE" == "error" ]] && continue
        if [[ "$RX_CUR" == "$RX_MAX" && "$TX_CUR" == "$TX_MAX" ]]; then
            pass "$NODE/$IFACE ($DRIVER): ring rx=$RX_CUR/$RX_MAX tx=$TX_CUR/$TX_MAX (at max)"
        else
            fail "$NODE/$IFACE ($DRIVER): ring rx=$RX_CUR/$RX_MAX tx=$TX_CUR/$TX_MAX (BELOW MAX)"
        fi
    done <<< "$RING_CHECK"
done
echo ""

# --- Summary ---
echo "============================================"
if [[ $FAILURES -eq 0 ]]; then
    echo -e " ${GREEN}ALL CHECKS PASSED${NC}"
else
    echo -e " ${RED}$FAILURES CHECK(S) FAILED${NC}"
fi
echo "============================================"

exit $((FAILURES > 0 ? 1 : 0))
