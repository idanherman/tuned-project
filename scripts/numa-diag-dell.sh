#!/bin/bash
# NUMA/NIC/CPU Diagnostics — Dell PowerEdge R6625/R7625 (AMD EPYC)
# Run as root on a worker node (via oc debug or SSH)
# Output is compact for screenshot capture
# Production safe — read-only, no changes made

echo "==== NUMA DIAG: $(hostname) ===="
echo "Date: $(date -u +%H:%M:%S) Kernel: $(uname -r)"
echo ""

# --- 1. CPU summary ---
echo "== 1. CPU =="
S=$(lscpu|awk '/^Socket/{print $2}')
C=$(lscpu|awk '/Core.s. per socket/{print $4}')
T=$(lscpu|awk '/Thread.s. per core/{print $4}')
L=$(nproc)
M=$(lscpu|grep "Model name"|head -1|sed 's/Model name: *//')
echo "$M | ${S}s x ${C}c x ${T}t = ${L} logical"
echo ""

# --- 2. NUMA topology ---
echo "== 2. NUMA =="
for n in /sys/devices/system/node/node[0-9]*; do
  N=$(basename $n)
  Cp=$(cat $n/cpulist)
  G=$(awk '/MemTotal/{printf "%.0fG",$4/1048576}' $n/meminfo)
  D=$(cat $n/distance)
  echo "$N: CPUs=$Cp RAM=$G dist=[$D]"
done
echo ""

# --- 3. HT siblings (compact) ---
echo "== 3. HT Siblings =="
for s in $(seq 0 $((S-1))); do
  pairs=""
  seen=""
  for cpu in /sys/devices/system/cpu/cpu[0-9]*/topology; do
    pkg=$(cat $cpu/physical_package_id 2>/dev/null)
    [ "$pkg" != "$s" ] && continue
    core=$(cat $cpu/core_id)
    sibs=$(cat $cpu/thread_siblings_list)
    c=$(basename $(dirname $cpu)|tr -dc '0-9')
    low=$(echo $sibs|cut -d, -f1)
    [ "$c" != "$low" ] && continue
    echo "$seen"|grep -q "c${core}=" && continue
    pairs="$pairs c${core}=[$sibs]"
    seen="$seen c${core}="
  done
  echo "Socket $s:$pairs"
done
echo ""

# --- 4. Physical NICs ---
echo "== 4. NICs (physical) =="
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  drv=$(basename $(readlink -f /sys/class/net/$i/device/driver 2>/dev/null) 2>/dev/null)
  [ -z "$drv" ] && continue
  numa=$(cat /sys/class/net/$i/device/numa_node 2>/dev/null)
  spd=$(cat /sys/class/net/$i/speed 2>/dev/null||echo ?)
  mtu=$(cat /sys/class/net/$i/mtu 2>/dev/null)
  rxq=$(ls -d /sys/class/net/$i/queues/rx-* 2>/dev/null|wc -l)
  state=$(cat /sys/class/net/$i/operstate 2>/dev/null)
  echo "$i: $drv numa=$numa ${spd}Mbps mtu=$mtu rx=$rxq $state"
done
echo ""

# --- 5. Bond info ---
echo "== 5. Bonds =="
for bond in $(ls /sys/class/net/|xargs -I{} sh -c 'cat /sys/class/net/{}/type 2>/dev/null|grep -q "^1$" && [ -d /sys/class/net/{}/bonding ] && echo {}'); do
  mode=$(cat /sys/class/net/$bond/bonding/mode 2>/dev/null)
  slaves=$(cat /sys/class/net/$bond/bonding/slaves 2>/dev/null)
  active=$(cat /sys/class/net/$bond/bonding/active_slave 2>/dev/null)
  echo "$bond: mode=$mode slaves=[$slaves] active=$active"
done
# If no bonds found via bonding dir, check trunk0
if [ -d /sys/class/net/trunk0 ]; then
  type=$(cat /sys/class/net/trunk0/type 2>/dev/null)
  if [ -d /sys/class/net/trunk0/bonding ]; then
    : # already printed above
  else
    echo "trunk0: type=$type (not a kernel bond, may be OVS/NM managed)"
  fi
fi
echo ""

# --- 6. Ring buffers ---
echo "== 6. Ring Buffers =="
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  max=$(ethtool -g $i 2>/dev/null|awk '/^RX:/{if(++n==1)print $2}')
  cur=$(ethtool -g $i 2>/dev/null|awk '/^RX:/{if(++n==2)print $2}')
  [ -z "$max" ] && continue
  echo "$i: RX max=$max cur=$cur"
done
echo ""

# --- 7. NIC features ---
echo "== 7. Features (first physical NIC) =="
FIRST_NIC=$(ls /sys/class/net/|grep -E "^(eno|ens|enp)" |head -1)
if [ -n "$FIRST_NIC" ]; then
  echo "($FIRST_NIC):"
  ethtool -k $FIRST_NIC 2>/dev/null|grep -E "ntuple|receive-hashing|rx-gro-hw|generic-receive"|head -5
fi
echo ""

# --- 8. IRQ affinity (physical NICs) ---
echo "== 8. IRQ->CPU =="
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em)"); do
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
# NUMA summary
echo "  --- IRQ NUMA summary ---"
n0=0; n1=0; nother=0
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  grep "$i" /proc/interrupts 2>/dev/null|while read line; do
    irq=$(echo "$line"|awk -F: '{print $1}'|tr -d ' ')
    cat /proc/irq/$irq/smp_affinity_list 2>/dev/null
  done
done|while read cpu; do
  first=$(echo $cpu|cut -d- -f1|cut -d, -f1)
  # Determine NUMA node from /sys
  numa=$(cat /sys/devices/system/node/node*/cpulist 2>/dev/null|awk -v c=$first '
    BEGIN{FS=","} {
      for(i=1;i<=NF;i++){
        split($i,r,"-");
        if(r[2]=="") r[2]=r[1];
        if(c>=r[1] && c<=r[2]){print NR-1; exit}
      }
    }')
  echo "N${numa:-?}"
done|sort|uniq -c|sort -rn
echo ""

# --- 9. Softnet ---
echo "== 9. Softnet =="
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

# --- 10. C-states ---
echo "== 10. C-States =="
for state in /sys/devices/system/cpu/cpu0/cpuidle/state*; do
  name=$(cat $state/name 2>/dev/null)
  lat=$(cat $state/latency 2>/dev/null)
  usage=$(cat $state/usage 2>/dev/null)
  dis=$(cat $state/disable 2>/dev/null)
  echo "  $name: lat=${lat}us usage=$usage dis=$dis"
done
echo ""

# --- 11. RFS ---
echo "== 11. RFS =="
echo "  rps_sock_flow_entries=$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null)"
echo ""

# --- 12. NIC drops ---
echo "== 12. NIC drops =="
for i in $(ls /sys/class/net/|grep -E "^(eno|ens|enp|eth[0-9]|em)"); do
  [ ! -e /sys/class/net/$i/device/driver ] && continue
  echo "  $i:"
  ethtool -S $i 2>/dev/null|grep -iE "drop|error|no_buf|discard|miss"|grep -v ": 0$"|sed 's/^/    /'
  [ $? -ne 0 ] && echo "    (all zero)"
done
echo ""

# --- 13. Kubelet ---
echo "== 13. Kubelet =="
grep -oE '"(cpuManager|topologyManager|systemReserved|podPidsLimit)[^}]*' /etc/kubernetes/kubelet.conf 2>/dev/null|head -8
echo ""

# --- 14. cgroup ---
echo "== 14. cgroup =="
stat -fc %T /sys/fs/cgroup 2>/dev/null

# --- 15. System model ---
echo ""
echo "== 15. HW Model =="
cat /sys/class/dmi/id/product_name 2>/dev/null
cat /sys/class/dmi/id/sys_vendor 2>/dev/null

echo ""
echo "==== END ===="
