#!/bin/bash
# NUMA/NIC/CPU Diagnostics — Cisco UCS C220-M5SX (pizza/rack-mount)
# Run as root on a worker node (via oc debug or SSH)
# Output is compact for screenshot capture
# Production safe — read-only, no changes made
#
# The C220 may have different NIC models than the B200 blades:
#   - Could be enic (VIC), i40e (Intel X710), or mlx5 (Mellanox ConnectX)
#   - This script auto-detects physical NICs
#
# Usage:
#   oc debug node/<node> -- chroot /host bash
#   # then paste this script

echo "==== NUMA DIAG: $(hostname) ===="
echo "Date: $(date -u +%H:%M:%S) Kernel: $(uname -r)"
echo ""

# --- 1. CPU summary (compact) ---
echo "== 1. CPU =="
S=$(lscpu|awk '/^Socket/{print $2}')
C=$(lscpu|awk '/Core.s. per socket/{print $4}')
T=$(lscpu|awk '/Thread.s. per core/{print $4}')
L=$(nproc)
M=$(lscpu|awk '/Model name/{$1=$2="";print}'|xargs)
echo "$M | ${S}s × ${C}c × ${T}t = ${L} logical"
echo ""

# --- 2. NUMA topology ---
echo "== 2. NUMA =="
for n in /sys/devices/system/node/node[0-9]*; do
  N=$(basename $n)
  C=$(cat $n/cpulist)
  G=$(awk '/MemTotal/{printf "%.0fG",$4/1048576}' $n/meminfo)
  D=$(cat $n/distance)
  echo "$N: CPUs=$C RAM=$G dist=[$D]"
done
echo ""

# --- 3. HT sibling pairs (grouped by socket, compact) ---
echo "== 3. HT Siblings =="
for s in $(seq 0 $((S-1))); do
  pairs=""
  for cpu in /sys/devices/system/cpu/cpu[0-9]*/topology; do
    pkg=$(cat $cpu/physical_package_id 2>/dev/null)
    [ "$pkg" != "$s" ] && continue
    core=$(cat $cpu/core_id)
    sibs=$(cat $cpu/thread_siblings_list)
    c=$(basename $(dirname $cpu)|tr -dc '0-9')
    # only print from lower-numbered sibling
    low=$(echo $sibs|cut -d, -f1)
    [ "$c" != "$low" ] && continue
    pairs="$pairs c${core}=[$sibs]"
  done
  echo "Socket $s:$pairs"
done
echo ""

# --- 4. Physical NICs (auto-detect) ---
echo "== 4. NICs (physical) =="
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em|iscsi|trunk)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  drv=$(basename $(readlink -f /sys/class/net/$i/device/driver 2>/dev/null) 2>/dev/null)
  [ -z "$drv" ] && continue
  numa=$(cat /sys/class/net/$i/device/numa_node 2>/dev/null)
  spd=$(cat /sys/class/net/$i/speed 2>/dev/null||echo ?)
  mtu=$(cat /sys/class/net/$i/mtu 2>/dev/null)
  rxq=$(ls -d /sys/class/net/$i/queues/rx-* 2>/dev/null|wc -l)
  state=$(cat /sys/class/net/$i/operstate 2>/dev/null)
  mac=$(cat /sys/class/net/$i/address 2>/dev/null|tail -c9)
  echo "$i: $drv numa=$numa ${spd}Mbps mtu=$mtu rx=$rxq $state ..${mac}"
done
echo ""

# --- 5. Ring buffers ---
echo "== 5. Ring Buffers =="
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em|iscsi|trunk)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  max=$(ethtool -g $i 2>/dev/null|awk '/^RX:/{if(++n==1)print $2}')
  cur=$(ethtool -g $i 2>/dev/null|awk '/^RX:/{if(++n==2)print $2}')
  [ -z "$max" ] && continue
  echo "$i: RX max=$max cur=$cur"
done
echo ""

# --- 6. NIC features ---
echo "== 6. Features =="
FIRST_NIC=$(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9])" |head -1)
if [ -n "$FIRST_NIC" ]; then
  echo "($FIRST_NIC):"
  ethtool -k $FIRST_NIC 2>/dev/null|grep -E "ntuple|receive-hashing|rx-gro-hw|generic-receive"|head -5
fi
echo ""

# --- 7. IRQ affinity (physical NICs) ---
echo "== 7. IRQ->CPU =="
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em|iscsi|trunk)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  count=$(grep -c "$i" /proc/interrupts 2>/dev/null)
  [ "$count" -eq 0 ] 2>/dev/null && continue
  echo "  $i ($count IRQs):"
  grep "$i" /proc/interrupts|while read line; do
    irq=$(echo "$line"|awk -F: '{print $1}'|tr -d ' ')
    name=$(echo "$line"|awk '{print $NF}')
    aff=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)
    echo "    $name irq=$irq cpu=$aff"
  done
done
echo "  --- IRQ NUMA summary ---"
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em|iscsi|trunk)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  grep "$i" /proc/interrupts 2>/dev/null|while read line; do
    irq=$(echo "$line"|awk -F: '{print $1}'|tr -d ' ')
    cat /proc/irq/$irq/smp_affinity_list 2>/dev/null
  done
done|while read cpu; do
  first=$(echo $cpu|cut -d- -f1|cut -d, -f1)
  numa=$(cat /sys/devices/system/node/node*/cpulist 2>/dev/null|awk -v c=$first \
    'BEGIN{FS=","}{for(i=1;i<=NF;i++){split($i,r,"-");if(r[2]=="")r[2]=r[1];if(c>=r[1]&&c<=r[2]){print NR-1;exit}}}')
  echo "N${numa:-?}"
done|sort|uniq -c|sort -rn
echo ""

# --- 8. Softnet stats ---
echo "== 8. Softnet =="
echo "CPU  packets     drops  squeeze"
cpu=0
while IFS= read -r line; do
  p=$((16#$(echo "$line"|awk '{print $1}')))
  d=$((16#$(echo "$line"|awk '{print $2}')))
  s=$((16#$(echo "$line"|awk '{print $3}')))
  if [ $p -gt 0 ]; then
    flag=""
    [ $d -gt 0 ] && flag=" !!DROP"
    [ $s -gt 100 ] && flag="$flag !!SQZ"
    printf "%-3d %10d %6d %6d%s\n" $cpu $p $d $s "$flag"
  fi
  cpu=$((cpu+1))
done < /proc/net/softnet_stat
echo ""

# --- 9. C-state usage ---
echo "== 9. C-States =="
for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
  name=$(cat $state/name 2>/dev/null)
  lat=$(cat $state/latency 2>/dev/null)
  usage=$(cat $state/usage 2>/dev/null)
  time=$(cat $state/time 2>/dev/null)
  dis=$(cat $state/disable 2>/dev/null)
  echo "  $name: latency=${lat}us usage=$usage time=${time}us disabled=$dis"
done
echo ""

# --- 10. RFS config ---
echo "== 10. RFS =="
echo "  rps_sock_flow_entries=$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null)"
rfs_count=0
for f in /sys/class/net/eth0/queues/rx-*/rps_flow_cnt; do
  v=$(cat $f 2>/dev/null)
  [ "$v" != "0" ] && rfs_count=$((rfs_count+1))
done
echo "  eth0 queues with rps_flow_cnt>0: $rfs_count"
echo ""

# --- 11. ethtool counters (drops) ---
echo "== 11. NIC drops =="
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em|iscsi|trunk)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  echo "  $i:"
  ethtool -S $i 2>/dev/null|grep -iE "drop|error|no_buf|discard|miss"|grep -v ": 0$"|sed 's/^/    /'
  [ $? -ne 0 ] && echo "    (all zero)"
done
echo ""

# --- 12. Kubelet config ---
echo "== 12. Kubelet =="
grep -oE '"(cpuManager|topologyManager|systemReserved|podPidsLimit)[^}]*' /etc/kubernetes/kubelet.conf 2>/dev/null|head -8
echo ""

# --- 13. cgroup version ---
echo "== 13. cgroup =="
stat -fc %T /sys/fs/cgroup 2>/dev/null
echo ""

# --- 14. Bonds ---
echo "== 14. Bonds =="
found_bond=0
for bond in $(ls /sys/class/net/ 2>/dev/null); do
  [ -d /sys/class/net/$bond/bonding ] || continue
  mode=$(cat /sys/class/net/$bond/bonding/mode 2>/dev/null)
  slaves=$(cat /sys/class/net/$bond/bonding/slaves 2>/dev/null)
  echo "$bond: mode=$mode slaves=[$slaves]"
  found_bond=1
done
[ $found_bond -eq 0 ] && echo "(none)"
echo ""

# --- 15. HW model ---
echo "== 15. HW Model =="
cat /sys/class/dmi/id/product_name 2>/dev/null
cat /sys/class/dmi/id/sys_vendor 2>/dev/null

echo ""
echo "==== END ===="
