#!/bin/bash
# NUMA/NIC/CPU Diagnostics — Cisco UCS B200 M5
# Run as root on a worker node (via oc debug or SSH)
# Output is compact for screenshot capture
# Production safe — read-only, no changes made
#
# Usage:
#   oc debug node/<node> -- chroot /host bash
#   # then paste this script, or:
#   bash /path/to/numa-diag-cisco-blade.sh

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

# --- 4. Physical NICs only ---
echo "== 4. NICs (physical) =="
for i in eth0 iscsi1 iscsi2 trunk0; do
  [ ! -d /sys/class/net/$i ] && continue
  drv=$(basename $(readlink -f /sys/class/net/$i/device/driver 2>/dev/null) 2>/dev/null)
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
for i in eth0 iscsi1 iscsi2 trunk0; do
  [ ! -d /sys/class/net/$i ] && continue
  max=$(ethtool -g $i 2>/dev/null|awk '/^RX:/{if(++n==1)print $2}')
  cur=$(ethtool -g $i 2>/dev/null|awk '/^RX:/{if(++n==2)print $2}')
  echo "$i: RX max=$max cur=$cur"
done
echo ""

# --- 6. NIC features (RSS/aRFS) ---
echo "== 6. Features (eth0) =="
ethtool -k eth0 2>/dev/null|grep -E "ntuple|receive-hashing|rx-gro-hw|generic-receive"|head -5
echo ""

# --- 7. IRQ affinity for enic ---
echo "== 7. IRQ→CPU (enic) =="
for i in eth0 iscsi1 iscsi2 trunk0; do
  grep -w "$i" /proc/interrupts 2>/dev/null|while read line; do
    irq=$(echo "$line"|awk -F: '{print $1}'|tr -d ' ')
    name=$(echo "$line"|awk '{print $NF}')
    aff=$(cat /proc/irq/$irq/smp_affinity_list 2>/dev/null)
    echo "  $name irq=$irq cpu=$aff"
  done
done
# count per NUMA
echo "  ---"
echo -n "  NUMA0 IRQs: "
for i in eth0 iscsi1 iscsi2 trunk0; do
  grep -w "$i" /proc/interrupts 2>/dev/null
done|while read line; do
  irq=$(echo "$line"|awk -F: '{print $1}'|tr -d ' ')
  cat /proc/irq/$irq/smp_affinity_list 2>/dev/null
done|while read cpu; do
  # check if first cpu in list is 0-13 or 28-41 (NUMA 0)
  first=$(echo $cpu|cut -d- -f1|cut -d, -f1)
  [ "$first" -le 13 ] 2>/dev/null && echo N0
  [ "$first" -ge 14 ] 2>/dev/null && [ "$first" -le 27 ] && echo N1
  [ "$first" -ge 28 ] 2>/dev/null && [ "$first" -le 41 ] && echo N0
  [ "$first" -ge 42 ] 2>/dev/null && echo N1
done|sort|uniq -c|xargs
echo -n "  NUMA1 IRQs: "
# (count is included in the line above)
echo "(see above)"
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
for i in eth0 iscsi1 iscsi2 trunk0; do
  [ ! -d /sys/class/net/$i ] && continue
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
echo "==== END ===="
