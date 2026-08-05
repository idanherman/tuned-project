# Packet Path: Wire to Application

How a network packet traverses the Linux kernel on an OCP node, and where each tuning parameter acts. Understanding this path explains WHY each parameter matters.

---

## The Path (Ingress — RX)

```
                                          ┌─ Tuning parameters ───────┐
 ① NIC Hardware                           │                          │
    Wire → PHY → MAC → DMA to RAM         │  ring=rx 4096            │
              ↓                           │  (ethtool -g)            │
 ② Ring Buffer (per-queue)                │                          │
    Fixed-size circular buffer in RAM     │                          │
    NIC writes descriptors here via DMA   │                          │
    If full → rx_no_bufs / ring_full      │                          │
              ↓                           │                          │
 ③ Hardware IRQ → Driver                  │  channels=combined 16    │
    NIC raises interrupt on assigned CPU  │  coalesce=rx-usecs 125   │
    Driver schedules NAPI poll            │  (interrupt rate limit)  │
              ↓                           │                          │
 ④ NAPI Poll (softirq context)            │  netdev_budget = 600     │
    Kernel polls ring buffer (no IRQ)     │  netdev_budget_usecs=4000│
    Batch-processes up to budget packets  │                          │
    If budget exhausted → squeeze         │                          │
              ↓                           │                          │
 ⑤ Per-CPU Backlog Queue                  │  netdev_max_backlog=5000 │
    Packets queued for protocol processing│                          │
    If full → softnet_drops               │                          │
              ↓                           │                          │
 ⑥ Protocol Processing (IP/TCP)           │                          │
    sk_buff → ip_rcv → tcp_v4_rcv         │                          │
    TCP reassembly, window management     │  tcp_rmem (window size)  │
    Receive buffer auto-tuning            │  rmem_max (cap)          │
              ↓                           │                          │
 ⑦ Socket Receive Buffer                  │  tcp_rmem = min init max │
    Per-socket buffer (auto-tuned)        │  rmem_max = hard ceiling │
    App reads from here via recv()        │                          │
              ↓                           │                          │
 ⑧ Application (in container/pod)         │                          │
    read()/recv() syscall                 │                          │
    accept() backlog for new connections  │  somaxconn = 10240       │
                                          │                          │
                                          └──────────────────────────┘
```

---

## Stage-by-Stage Explanation

### ① NIC Hardware

The physical NIC receives frames from the wire. In virtualized environments (vmxnet3), the hypervisor's virtual switch delivers frames to the virtual NIC.

Modern NICs don't have a single receive path — they have multiple independent **queues** (also called channels). Each queue is a separate processing pipeline with its own ring buffer and its own CPU assignment. The NIC distributes incoming packets across queues using **RSS (Receive Side Scaling)**: it hashes each packet's 5-tuple (source IP, destination IP, source port, destination port, protocol) and maps the hash to a queue. This means different network flows land on different CPUs and are processed in parallel.

The number of queues determines how many CPUs participate in packet processing. The parameter `channels=combined N` controls this. The ideal N equals cores per NUMA node — more queues than local cores forces cross-NUMA memory access (~100ns penalty per packet). Typical examples:
- vmxnet3: 8 queues (VMware sets this to min(vCPUs, 8) automatically)
- enic: 8 RX + 8 TX (configured at UCS adapter policy)
- i40e: `channels=combined 16` (match to cores per NUMA — verify for your hardware)
- bnxt_en: `channels=combined 16` (verify NUMA topology on your hardware)

**Tuning lever:** Queue count is set at firmware (enic) or via TuneD `[net]` section (i40e, bnxt_en). VMware manages it automatically.

---

### ② Ring Buffer (one per queue)

A fixed-size circular queue in host RAM, shared between NIC hardware and the driver. Each RX queue has its own independent ring buffer. The NIC writes packet descriptors via DMA; the driver reads them during NAPI poll.

With 8 queues and ring=4096, there are 8 × 4096 = 32,768 descriptor slots total across all queues. RSS distributes incoming flows across them.

**What goes wrong:** If a ring fills up before the kernel drains it, incoming packets for THAT queue are dropped at the hardware level — these show as `ring_full` (vmxnet3), `rx_no_bufs` (enic), `rx_missed_errors` (i40e). A single hot flow can overflow one queue while others are empty (hash collision or flow imbalance).

**Common finding:** vmxnet3 default ring is RX=1024/TX=512. Maximum is 4096. If you see millions of `ring_full` drops, the ring is the bottleneck.

**Tuning:**
```ini
[net]
ring=rx 4096 tx 4096
```

**Tradeoff — bufferbloat explained:**

The concern with large buffers is called "bufferbloat." Here's the paradox: dropping a packet is sometimes BETTER than queueing it. That sounds wrong, but it makes sense once you understand how TCP congestion control works:

1. TCP sender transmits at increasing speed until something signals "slow down"
2. The ONLY signal TCP understands is packet loss (or ECN, but that's rare)
3. If buffers are huge, packets sit in a queue for a long time instead of being dropped
4. TCP never sees a drop → never slows down → keeps filling the buffer
5. Result: every packet experiences the full queue delay (hundreds of milliseconds)
6. New flows sharing the same link also get stuck behind the bloated queue
7. Interactive traffic (SSH, API calls) becomes sluggish because it's queued behind bulk transfers

With a SMALL buffer: the bulk transfer fills the buffer quickly → packet drops → TCP backs off → buffer drains → latency returns to normal. The drop is the feedback signal.

With a HUGE buffer: the bulk transfer fills the buffer slowly (more room) → no drops for a long time → TCP thinks the path is clear and keeps accelerating → the buffer eventually fills completely → ALL traffic queued for a long time → everything is slow.

**Why bufferbloat does NOT apply in typical OCP environments:**

Bufferbloat is a problem when you have a congested LINK (the pipe is full, and you're choosing between drop vs queue). OCP clusters are typically different:

- Links are not congested — 10GbE links are nowhere near saturated
- Drops happen because the KERNEL is too slow to drain the ring (CPU-bound, not link-bound)
- Packets are being dropped not because the network is full, but because the software can't keep up with burst arrival
- Larger ring gives the kernel more TIME to catch up during bursts, then the ring drains normally
- You're not adding latency — you're preventing packet loss during short burst spikes

Bufferbloat would be a concern on a congested WAN link at 95% utilization where TCP needs drop signals to regulate sender speed. On an internal OCP cluster with 10GbE links at moderate utilization, the ring buffer is just burst absorption — not a congestion queue.

**Memory cost:** Each ring buffer slot is a descriptor (~16 bytes) pointing to a pre-allocated packet buffer (typically 2KB). So ring=4096 per queue = 4096 × ~2KB = ~8MB per queue. With 8 queues × 2 directions (RX + TX) = ~128MB per NIC. This is allocated at NIC initialization and held for the entire node uptime — it's a permanent reservation, not dynamic. At default ring=1024/512, the cost was ~48MB. Increasing to 4096/4096 adds ~80MB per NIC. On a node with 64GB+ RAM, this is negligible.

**Bottom line:** Ring at 4096 = burst absorption, not bufferbloat. If you see millions of drops at default ring sizes, the ring was too small — the link was not congested.

**Why sequential on masters:** Resizing the ring causes a brief (~1s) NIC reset. All in-flight packets are lost. etcd uses TCP, so it retransmits — but if all 3 masters reset simultaneously, the etcd cluster may briefly lose quorum.

---

### ③ Hardware IRQ and Interrupt Coalescing

When packets arrive in a queue's ring buffer, the NIC needs to tell the CPU "you have work to do." It does this by raising an **IRQ (Interrupt Request)** — a hardware signal that forces the CPU to immediately stop whatever it's running (a pod process, kubelet, anything) and jump to a special function called the interrupt handler. Nothing else can run on that CPU while the interrupt handler executes — it has absolute priority.

Each queue has its own IRQ, assigned to a specific CPU core via **MSI-X** (Message Signaled Interrupts — a mechanism that lets a device target a specific CPU directly, unlike old-style shared interrupts). This is why queue count maps to CPU count: queue 0's IRQ goes to CPU 2, queue 1's IRQ goes to CPU 5, etc. (the mapping is configured by the driver or `irqbalance`).

The IRQ handler itself is deliberately tiny and fast (a few microseconds). It does only two things: (1) disable further interrupts for this queue (so the NIC doesn't keep interrupting while we're already handling it), and (2) schedule the real packet processing for later. The actual heavy lifting — pulling packets from the ring, parsing headers, running through the network stack — happens in the next stage (NAPI/softirq).

**Why interrupt coalescing exists:** Without it, a 10GbE NIC receiving small packets could generate 14 million IRQs per second. Each IRQ forces a context switch, cache flush, and handler execution — the CPU would spend 100% of its time just entering and exiting interrupt handlers with zero time for actual packet processing. Coalescing tells the NIC: "wait up to N microseconds and collect multiple packets before raising one IRQ for the batch."

- `rx-usecs 125` = wait up to 125 microseconds, then interrupt (batches ~1000+ packets at 10GbE)
- `adaptive-rx on` = driver dynamically adjusts the delay (shorter under low traffic for low latency, longer under high traffic for efficiency)

**Recommended settings:**
- vmxnet3: leave default (VMware manages coalescing at the hypervisor level)
- enic: 125us at UCS adapter policy (working fine)
- i40e: explicit 125us, adaptive OFF (Intel recommends fixed for predictable latency)
- bnxt_en: adaptive ON (Broadcom's implementation handles dynamic workloads well)

---

### ④ NAPI Poll (softirq context)

The IRQ handler scheduled the real work. Now it runs — but not as a regular process and not as a hardware interrupt. It runs as a **softirq** (software interrupt): a kernel execution context that sits between hardware IRQs and normal processes in priority. The priority hierarchy on a CPU is:

```
Hardware IRQ    ← highest: nothing can preempt this
  softirq      ← runs after IRQ, preempts normal processes
    processes   ← pods, kubelet, CRI-O — lowest priority
```

So while softirq is processing packets, all pods and system services on that CPU are frozen. The CPU is 100% dedicated to network processing until the softirq yields.

**NAPI (New API)** is the mechanism that runs inside this softirq. Instead of one-interrupt-per-packet (which would be millions of IRQs/sec at 10GbE), NAPI uses a smarter model: the single hardware IRQ from stage ③ triggers NAPI, which then **polls** the ring buffer in a loop — pulling and processing packets one after another without any further interrupts. The NIC's interrupts for this queue stay disabled the entire time. Only when NAPI decides it's done (ring empty or budget exhausted) does it re-enable interrupts and yield the CPU back to normal processes.

This polling approach is what makes 10GbE+ feasible on Linux. Without NAPI, the CPU would spend all its time entering/exiting interrupt handlers and never actually process a packet.

**Budget controls (when NAPI stops polling and yields the CPU):**
- `netdev_budget = 600` — max packets processed across ALL queues per NAPI cycle
- `netdev_budget_usecs = 4000` — max TIME spent before forcibly yielding

NAPI stops when EITHER limit is hit first. If the time budget runs out before processing 600 packets, the higher packet count is wasted.

**What goes wrong:** If budget is exhausted but the ring still has packets waiting, a "time squeeze" occurs (`softnet_stat` column 3). The kernel re-schedules NAPI for the next softirq cycle — but during the gap, new packets pile up in the ring buffer and may overflow it.

**Why this matters for VMs specifically:** While NAPI holds the CPU in softirq, the hypervisor's scheduler sees the vCPU as "busy but not yielding." If softirq runs for too long, the hypervisor may penalize the VM (reduce its scheduling priority or co-stop paired vCPUs). This is why budget should stay low on VMs (default 300/2000us) but can be raised on bare-metal (600/4000us) where there's no hypervisor to anger.

**Why budget_usecs=4000 on BM:** At 10GbE+ speeds, 2000us (default) is too short to process 600 packets. The time limit fires first and NAPI yields prematurely. Doubling the time ensures the packet count is the real limiter.

---

### ⑤ Per-CPU Backlog Queue

After NAPI pulls packets from the ring, they enter a per-CPU backlog queue waiting for protocol stack processing (IP, TCP). This queue exists because protocol processing (checksums, routing lookups, conntrack) is slower than raw ring-to-memory copying.

Each CPU has its own independent backlog queue. Packets stay on the CPU that received them (the IRQ/NAPI CPU) — they don't move between CPUs at this stage.

**What goes wrong:** If the queue (size = `netdev_max_backlog`) overflows, packets are silently dropped. These appear as `softnet_drops` (column 2 of `/proc/net/softnet_stat`). Unlike ring drops, these happen AFTER the packet was successfully received from the NIC — the kernel accepted it but then threw it away because the processing pipeline was backed up.

**Example finding:** millions of softnet_drops on bare-metal workers with `backlog=1000`. At 10GbE+ with OVN-K encapsulation overhead (every pod packet traverses the host stack), 1000 slots is insufficient for burst absorption.

**Tuning:**
```ini
net.core.netdev_max_backlog = 5000
```

**Why 5000:** RH KCS 1241943 recommends doubling until drops stop, up to 10000. Start at 5000 (5x default) and verify with `softnet_stat`.

---

### ⑥ TCP Protocol Processing

Packets reach `tcp_v4_rcv()`. TCP manages:
- Sequence numbers and reassembly
- Receive window advertisement (tells sender how much to send)
- Window auto-tuning (dynamically grows receive buffer based on BDP)

**The enic regression (RHEL-97545 / KCS 7127975):**

TCP window auto-tuning calculates the optimal receive buffer size based on RTT and bandwidth. In RHEL 9.4, a regression in the enic driver path breaks this calculation — the kernel fails to grow the window beyond the initial `tcp_rmem` value.

With the RHEL default `tcp_rmem = 4096 131072 6291456`:
- Initial window = 131072 bytes (128KB)
- Auto-tuning should grow it toward max (6MB) based on BDP
- On enic: **it never grows** — stuck at 128KB

At 10GbE with 1ms RTT: BDP = 10Gbps × 1ms = 1.25MB. A 128KB window limits throughput to ~1Gbps — hence 12-hour image pulls.

**Fix:**
```ini
net.ipv4.tcp_rmem = 4096 3145728 6291456
```
Setting initial to 3MB (3145728) bypasses auto-tuning entirely — every connection starts with a 3MB window. Wasteful on memory, but correct throughput.

---

### ⑦ Socket Receive Buffer

Each TCP socket has a receive buffer capped by `rmem_max`. The `tcp_rmem` max value cannot exceed `rmem_max`.

```
tcp_rmem = min  initial  max
             │      │      │
             │      │      └── per-socket ceiling (auto-tuned up to this)
             │      └── starting buffer size for new connections
             └── absolute minimum (never shrink below)

rmem_max = hard system-wide cap (applies to ALL socket types, not just TCP)
```

**Recommended:** `rmem_max = 16777216` (16MB) on BM nodes if using iSCSI or large block transfers. This ensures tcp_rmem max of 6-16MB is achievable.

---

### ⑧ Application Listen Backlog (somaxconn)

When a server calls `listen(fd, backlog)`, the kernel queues incoming connections that have completed the TCP handshake but haven't been `accept()`ed yet. The queue size is `min(backlog, somaxconn)`.

**HAProxy on infra nodes:** HAProxy sets a large listen backlog for its frontends. If connection bursts exceed the accept queue, clients get TCP RST (connection refused).

**Recommended:**
- Infra/router nodes: `somaxconn = 10240` (RH Performance Scaling Guide recommendation)
- All others: kernel default 4096 (sufficient for kubelet, CRI-O, apiserver)
- **Remove** the legacy `655535` — it was from RHEL 7 days when the default was 128

---

## The Path (Egress — TX)

```
                                         ┌─ Tuning parameters ─────┐
 ① Application send()                    │                         │
    write()/send() syscall               │                         │
    Data copied into socket TX buffer    │  tcp_wmem (buffer size) │
              ↓                          │  wmem_max (cap)         │
 ② Socket Send Buffer                    │                         │
    Per-socket buffer (auto-tuned)       │                         │
    TCP flow control: can't send more    │                         │
    than receiver's advertised window    │                         │
              ↓                          │                         │
 ③ TCP Segmentation                      │                         │
    Breaks data into MSS-sized segments  │                         │
    Adds TCP header, sequence numbers    │                         │
    Congestion window limits in-flight   │                         │
              ↓                          │                         │
 ④ IP Routing                            │                         │
    Adds IP header, determines next hop  │                         │
    Netfilter / conntrack processing     │  nf_conntrack_max       │
              ↓                          │                         │
 ⑤ Queueing Discipline (qdisc)           │                         │
    Per-interface output queue           │                         │
    Default: fq_codel (fair queueing)    │                         │
    Schedules which packet transmits next│                         │
              ↓                          │                         │
 ⑥ Driver TX Ring                        │  ring=tx 4096           │
    DMA descriptors for NIC to read      │                         │
    If full → TX drops (ring_full)       │                         │
              ↓                          │                         │
 ⑦ NIC DMA → Wire                        │                         │
    NIC reads descriptors, transmits     │                         │
    TSO offload (segment in hardware)    │                         │
                                         └─────────────────────────┘
```

---

### ① Application send()

The application calls `send()` or `write()`. Data is copied from userspace into the kernel's per-socket send buffer. If the buffer is full (sender is faster than the network can drain), `send()` blocks (blocking mode) or returns `EAGAIN` (non-blocking).

**Tuning lever:** `tcp_wmem` initial determines starting send buffer size. Auto-tuning grows it toward max based on congestion window.

---

### ② Socket Send Buffer

Each TCP socket has a send buffer sized by `tcp_wmem` (min/initial/max), capped by `wmem_max`. Data sits here until the receiver ACKs it (TCP guarantees delivery — data stays in send buffer until ACKed so it can be retransmitted if needed).

**What goes wrong:** If `wmem_max` is too small, the send buffer caps out and the application blocks on `send()`. For iSCSI initiators sending large blocks, 16MB is needed.

**Recommended:** BM nodes with iSCSI need `wmem_max=16MB`. VMs can use default 208KB (sufficient for control-plane traffic).

---

### ③ TCP Segmentation

TCP breaks the data stream into segments of MSS (Maximum Segment Size, typically 1448 bytes for standard MTU). It adds TCP headers and manages:
- **Sequence numbers** — for ordering and retransmission
- **Congestion window (cwnd)** — limits packets in flight based on network capacity
- **Flow control** — respects receiver's advertised window (this is where the RX-side `tcp_rmem` regression matters — if receiver advertises a small window, sender throttles)

With TSO (TCP Segmentation Offload) enabled, the kernel can hand the NIC a large chunk (up to 64KB) and the NIC segments it into MSS-sized frames in hardware — dramatically reducing per-packet CPU overhead.

---

### ④ IP Routing and Netfilter

The IP layer adds headers, looks up the routing table for the output interface, and passes through netfilter hooks (conntrack, NAT, network policy rules). In OVN-K, this is where Geneve encapsulation happens for cross-node pod traffic.

**What goes wrong:** If `nf_conntrack_max` is exhausted, NEW connections are dropped here (the `insert_failed` counter). This affects TX for outgoing connections.

---

### ⑤ Queueing Discipline (qdisc)

Each network interface has an output queue managed by a qdisc (queueing discipline). RHCOS uses `fq_codel` by default — a fair-queue + controlled-delay algorithm that prevents bufferbloat by keeping queue latency low and distributing bandwidth fairly across flows.

For most OCP workloads, the default qdisc is fine. The queue length (`txqueuelen`, default 1000) is rarely a bottleneck because the NIC TX ring is the actual limiter.

---

### ⑥ Driver TX Ring

The TX ring buffer is the mirror of the RX ring — a circular queue of DMA descriptors that the NIC reads to know which packets to transmit. The driver writes descriptors (pointing to packet data in RAM); the NIC reads them and DMAs the data onto the wire.

**What goes wrong:** If the application/kernel produces packets faster than the NIC can transmit (link saturation, flow control pauses, or NIC stall), the TX ring fills up. New packets are dropped — these show as `ring_full` on vmxnet3.

**Typical symptom:** vmxnet3 control-plane nodes with hundreds of millions of `ring_full` drops at TX ring=512 (default). These are TX-direction drops — the kernel is trying to send (etcd replication, API server responses) faster than the 512-slot ring can drain.

**Fix:** `ring=tx 4096` — 8x more slots to absorb burst production.

---

### ⑦ NIC Transmission

The NIC reads descriptors from the TX ring via DMA, fetches packet data from RAM, and puts frames on the wire. If TSO is enabled, the NIC segments large payloads into MTU-sized frames in hardware.

On vmxnet3, this is a virtual operation — the hypervisor's vSwitch receives the "transmitted" frame and delivers it to the destination VM or physical uplink.

---

### TX vs RX: Why RX tuning dominates

Most NTO tuning focuses on the RX path because:
1. The kernel has more queuing stages on RX (NAPI, backlog) that can overflow
2. RX is interrupt-driven — the NIC pushes data at the kernel's pace, not the app's
3. TX is application-driven — the app controls send rate, and TCP congestion control naturally throttles

The typical TX-specific problem (`ring_full` on vmxnet3) is solved by the same ring buffer increase that fixes RX drops — `ring=rx 4096 tx 4096` addresses both directions.

---

## OVN-Kubernetes Overlay Impact

In OVN-K, pod traffic is encapsulated in Geneve tunnels:

```
Pod → veth → OVS bridge → Geneve encap → physical NIC TX
Physical NIC RX → Geneve decap → OVS bridge → veth → Pod
```

This means:
- Every pod packet traverses the host NIC (even pod-to-pod on different nodes)
- Encapsulation adds ~50 bytes overhead per packet
- The physical NIC's ring buffer, backlog, and budget handle ALL pod traffic
- Higher packet rates than a traditional single-application host

This is why default kernel values (designed for single-server workloads) are insufficient on OCP nodes handling hundreds of pods.

---

## Parameter Interaction Map

```
                    ┌──────────────────────────────────────────┐
                    │         Packet Rate Bottlenecks          │
                    │                                          │
  ring too small ───┤   Symptom: ring_full, rx_no_bufs         │
                    │   Fix: ring=rx 4096 tx 4096              │
                    │                                          │
  poll too short ───┤   Symptom: squeeze (softnet_stat col 3)  │
                    │   Fix: netdev_budget=600,                │
                    │        netdev_budget_usecs=4000          │
                    │                                          │
  backlog too small─┤   Symptom: softnet_drops                 │
                    │   Fix: netdev_max_backlog=5000           │
                    └──────────────────────────────────────────┘

                    ┌──────────────────────────────────────────┐
                    │       Throughput Bottlenecks             │
                    │                                          │
  window too small ─┤   Symptom: slow transfers, low goodput   │
                    │   Fix: tcp_rmem initial=3MB (enic bug)   │
                    │                                          │
  buffer cap ───────┤   Symptom: window capped below BDP       │
                    │   Fix: rmem_max=16MB, wmem_max=16MB      │
                    └──────────────────────────────────────────┘

                    ┌──────────────────────────────────────────┐
                    │       Connection Bottlenecks             │
                    │                                          │
  accept queue ─────┤   Symptom: TCP RST on connect, ECONNREF  │
                    │   Fix: somaxconn=10240 (router nodes)    │
                    └──────────────────────────────────────────┘
```

---

## Memory Impact Summary

Every buffer increase consumes kernel memory. Some are allocated once at boot and held permanently, others scale with active connections/sockets and are freed when those sockets close.

**Persistent (held for entire node uptime):** ring buffers, netdev_max_backlog.
**Dynamic (scales with usage, freed on socket close):** tcp_rmem, tcp_wmem, somaxconn accept queues, tcp_max_syn_backlog.

### Bare-metal workers (enic) — worst case

| Parameter | How it allocates | Per-node cost |
|-----------|-----------------|---------------|
| Parameter | Allocation type | Per-node cost |
|-----------|----------------|---------------|
| Ring buffers (4096 × 8 queues × RX+TX) | **Persistent** — allocated at NIC init | ~128MB (already allocated — UCS manages ring) |
| netdev_max_backlog = 5000 | **Persistent** — per-CPU array at boot | ~640KB (16-core node) |
| tcp_rmem initial = 3MB | **Dynamic** — per connection, freed on close | **3MB × active connections** |
| tcp_wmem initial = 87KB | **Dynamic** — per connection, freed on close | ~85KB × active connections |
| rmem_max / wmem_max = 16MB | Ceiling only — doesn't allocate by itself | 0 (just a cap) |
| somaxconn = 4096 | **Dynamic** — per listening socket, freed on close | ~1MB per listener at capacity |
| netdev_budget / budget_usecs | Just integer sysctls, no buffers | 0 |

**tcp_rmem is the big one.** With `initial=3MB`, every new TCP connection immediately allocates a 3MB receive buffer. On a worker node with 500 active connections:
- **With tcp_rmem=3MB workaround:** 500 × 3MB = **~1.5GB** for receive buffers + 500 × 85KB = ~42MB for send buffers
- **With defaults:** 500 × 128KB = 64MB for receive (auto-tuning grows only what's needed) + 500 × 16KB = 8MB for send

The enic workaround costs ~1.4GB extra in receive buffers. tcp_wmem is not a concern (85KB initial is modest). Both are freed when connections close — so idle nodes use less, busy nodes use more.

On nodes with 64GB+ RAM, 1.5GB for TCP buffers is acceptable (~2.3% of total). Monitor with `cat /proc/net/sockstat` (TCP mem field shows pages currently used).

### VMware workers — minimal impact

| Parameter | Per-node cost |
|-----------|---------------|
| Ring buffers (4096 × 8 queues × RX+TX) | ~128MB (up from ~48MB at defaults) |
| THP=never | Actually SAVES memory (no compaction overhead, no 2MB page reservation) |
| kernel.printk | 0 |

Net increase: **~80MB per VM** over defaults. Negligible.

### Infra/router nodes — moderate

| Parameter | Per-node cost |
|-----------|---------------|
| Parameter | Allocation type | Per-node cost |
|-----------|----------------|---------------|
| Ring buffers | **Persistent** | ~128MB (up ~80MB from default) |
| somaxconn = 10240 | **Dynamic** — per listener × queue depth | ~25MB if HAProxy accept queues fill |
| tcp_max_syn_backlog = 8192 | **Dynamic** — per listener × SYN queue | ~16MB if SYN queues fill (unlikely in normal operation) |
| fs.file-max / fs.nr_open = 2M | Ceiling only | 0 |
| ip_local_port_range | Just changes range | 0 |
| vm.max_map_count | Just raises limit | 0 |

Net increase: **~80MB persistent** (ring buffers) + up to ~40MB dynamic under heavy connection load.

### Total across the cluster

| Node type | Count | Extra memory per node | Total |
|-----------|-------|----------------------|-------|
| Masters | 3 | ~80MB (ring only) | ~240MB |
| Infra | 4 | ~80MB | ~320MB |
| BM workers | 20 | ~80MB ring + 1-2GB tcp_rmem (connection-dependent) | ~2-4GB per node |

**Summary:** Ring buffers are the only truly persistent cost (~80MB extra per node). Everything TCP-related (tcp_rmem, tcp_wmem, somaxconn, syn_backlog) is dynamic — allocated when connections are active, freed when they close. The tcp_rmem=3MB initial on enic is the largest dynamic cost and scales with connection count.

---

## Errors vs Drops — What's the Difference?

These are two different kinds of "packet didn't make it" and they mean different things:

**Errors** = the packet arrived but was malformed or corrupted. The NIC or kernel checked the data and rejected it:
- CRC errors (bit flipped during transmission — bad cable, EMI, failing transceiver)
- Runt frames (too short — collision or hardware fault)
- Giant frames (too large for configured MTU)
- Checksum failures (IP/TCP/UDP checksum doesn't match payload)

Errors point to **hardware/physical layer problems**: bad cables, failing NICs, duplex mismatch, overheating transceivers.

**Drops** = the packet was valid but the system couldn't handle it in time. Nothing was wrong with the data — the system just ran out of space or time:
- Ring buffer full (NIC received faster than kernel could drain)
- Backlog queue full (kernel received faster than TCP stack could process)
- Conntrack table full (too many connections for the table size)
- Memory exhaustion (couldn't allocate buffer for the packet)

Drops point to **capacity/tuning problems**: buffers too small, CPU too slow, too many connections.

**Key insight:** Errors are typically LOW (single digits to hundreds) and indicate something is physically broken. Drops can be in the MILLIONS and indicate the system is overwhelmed but healthy hardware-wise. A cluster with near-zero errors but hundreds of millions of drops has a pure tuning problem, not a hardware problem.

---

## Drop Counters by Driver

All counters are cumulative since boot. They only go up. To measure rate, compare two readings separated by time (or use uptime from `cat /proc/uptime`).

### vmxnet3 (VMware VMs)

```bash
# Per-NIC driver-specific drops (the important ones for us)
ethtool -S eth0 | grep -E 'ring full|OOB'
```

| Counter | Meaning | Stage | Fix |
|---------|---------|-------|-----|
| `Tx ring N ring full` | TX ring buffer overflow — kernel producing faster than NIC can send | ② TX ring | ring=tx 4096 |
| `pkts rx OOB` | RX packets received when ring was full (out-of-buffer) | ② RX ring | ring=rx 4096 |

```bash
# Generic interface stats (aggregated — less detail)
ip -s link show eth0
```
The `RX: errors` and `TX: errors` lines show kernel-level counters. On vmxnet3 these are usually 0 — the real story is in `ethtool -S`.

### enic (Cisco UCS)

```bash
# Per-NIC driver-specific drops
ethtool -S eth0 | grep -E 'rx_no_bufs|rx_drop|tx_drop'
```

| Counter | Meaning | Stage | Fix |
|---------|---------|-------|-----|
| `rx_no_bufs` | RX ring ran out of descriptors (NIC had packet, no buffer to put it in) | ② RX ring | Already at 4096 (UCS) |
| `rx_drop` | Packets dropped by hardware filter/policy | ① NIC HW | Usually 0 — investigate if non-zero |
| `tx_drop` | TX couldn't be queued | ⑥ TX ring | Rare on enic |

```bash
# Per-queue breakdown (enic reports per-queue)
ethtool -S eth0 | grep -E 'rq[0-9].*drop|rq[0-9].*no_bufs'
```

### i40e (Intel X710)

```bash
# Per-NIC driver-specific drops
ethtool -S eth0 | grep -E 'rx_dropped|rx_missed|tx_dropped'
```

| Counter | Meaning | Stage | Fix |
|---------|---------|-------|-----|
| `rx_dropped` | Packets dropped by driver (no room in ring or allocation failure) | ② RX ring | ring=rx 4096 |
| `rx_missed_errors` | Packets the NIC saw on the wire but couldn't DMA (ring full) | ② RX ring | ring=rx 4096 |
| `tx_dropped` | TX packets dropped | ⑥ TX ring | ring=tx 4096 |

```bash
# Useful: per-queue stats
ethtool -S eth0 | grep -E 'tx_queue_[0-9]+_packets|rx_queue_[0-9]+_packets'
```

### bnxt_en (Broadcom)

```bash
# Per-NIC driver-specific drops
ethtool -S eth0 | grep -E 'rx_discard|rx_error|tx_discard'
```

| Counter | Meaning | Stage | Fix |
|---------|---------|-------|-----|
| `rx_discard_pkts` | Valid packets discarded (ring full or filter) | ② RX ring | ring=rx 4096 |
| `rx_error_pkts` | Malformed/errored packets | ① Physical | Check cables |
| `tx_discard_pkts` | TX drops | ⑥ TX ring | ring=tx 4096 |

---

## Kernel-Level Drop Counters (all drivers)

These are above the NIC driver — they show drops in the Linux network stack itself:

### softnet_stat (backlog drops and squeezes)

```bash
cat /proc/net/softnet_stat
```

Each line is one CPU. Columns are hex values:

| Column | Meaning | Stage | Fix |
|--------|---------|-------|-----|
| 1 | Total packets processed by this CPU | — | (informational) |
| 2 | **Packets dropped** (backlog queue full) | ⑤ backlog | netdev_max_backlog=5000 |
| 3 | **Time squeezes** (NAPI budget exhausted, ring not fully drained) | ④ NAPI | netdev_budget=600, budget_usecs=4000 |

```bash
# Human-readable sum across all CPUs
awk '{dropped += strtonum("0x"$2); squeezed += strtonum("0x"$3)}
     END {print "softnet_drops:", dropped, "\nsqueezes:", squeezed}' /proc/net/softnet_stat
```

### ip -s link (generic interface summary)

```bash
ip -s link show eth0
```

Output shows:
```
RX: bytes  packets  errors  dropped  missed  mcast
TX: bytes  packets  errors  dropped  carrier  collsns
```

- **RX errors** = driver-reported receive errors (CRC, runt, etc.)
- **RX dropped** = packets dropped by the kernel AFTER the driver delivered them (see below)
- **RX missed** = NIC-level drops (maps to `rx_missed_errors` on i40e, `rx_no_bufs` on enic)
- **TX errors** = send failures (link down, driver errors)
- **TX dropped** = TX packets the kernel couldn't queue

**What counts in RX dropped (and what doesn't):**

RX dropped in `ip -s link` includes:
- Netfilter/iptables DROP rules (packet matched a policy rejection)
- Socket receive buffer full (UDP — no room in the destination socket)
- Conntrack table full (nf_conntrack_max exceeded)
- No matching socket (destination port has no listener)
- VLAN mismatch or protocol with no handler registered

RX dropped does **NOT** include:
- NIC ring buffer drops (`ring_full`, `rx_no_bufs`) — those happen at hardware level, before kernel accounting
- softnet_drops (backlog queue overflow) — tracked separately in `/proc/net/softnet_stat`

So if you see RX dropped > 0 in `ip -s link` but softnet_drops = 0 and ethtool shows no ring drops, the problem is at the protocol/socket layer (netfilter, conntrack, or application not reading fast enough).

**How to determine WHICH cause is incrementing RX dropped:**

```bash
# 1. Check conntrack (is the table full?)
sysctl net.netfilter.nf_conntrack_count   # current usage
sysctl net.netfilter.nf_conntrack_max     # maximum
conntrack -S | grep -E 'insert_failed|drop'

# 2. Check UDP socket overflows
cat /proc/net/snmp | grep Udp
# Look at: RcvbufErrors (socket buffer full), InErrors (checksum + other)
nstat -z | grep UdpRcvbufErrors

# 3. Check TCP (TCP rarely drops — it uses flow control instead)
nstat -z | grep -E 'TcpExtListenDrops|TcpExtListenOverflows'
# ListenOverflows = SYN arrived but accept queue was full (somaxconn)
# ListenDrops = incoming connection dropped (includes overflows + other)

# 4. Check netfilter drops (are firewall rules dropping packets?)
# On OVN-K nodes, nftables/iptables implement NetworkPolicy:
iptables -L -v -n 2>/dev/null | grep -i drop | head -10
nft list ruleset 2>/dev/null | grep -c drop

# 5. Kernel drop reason tracing (most detailed — shows exact function)
# Requires perf or dropwatch tool:
perf trace -e skb:kfree_skb -a --duration 10 2>/dev/null | head -20
# Or on newer kernels:
cat /sys/kernel/debug/tracing/events/skb/kfree_skb/format  # see available reasons
```

**Relationship between counters at each stage:**

```
NIC ring drops         → ethtool -S (ring_full, rx_no_bufs)     NOT in ip -s link
softnet_drops          → /proc/net/softnet_stat column 2         NOT in ip -s link
Protocol/socket drops  → ip -s link RX dropped                   THIS is what ip shows
TCP retransmissions    → nstat TcpRetransSegs                    (not a "drop" counter)
```

These are independent — you need to check all three levels to get the full picture.

### conntrack (connection tracking drops)

```bash
conntrack -S
```

| Field | Meaning | Fix |
|-------|---------|-----|
| `insert_failed` | New connection couldn't be tracked (table full) | nf_conntrack_max |
| `drop` | Packet dropped due to conntrack | Investigate rule/state |

---

## TX Drop Counters by Driver

TX drops happen when the kernel produces packets faster than the NIC can transmit them (stage ⑥ in the TX path). `ring_full` on vmxnet3 control-plane nodes are TX drops.

### vmxnet3

```bash
ethtool -S eth0 | grep -E 'ring full|stopped'
```

| Counter | Meaning | Fix |
|---------|---------|-----|
| `Tx ring N ring full` | TX ring overflow — kernel queued a packet but ring had no free descriptors | ring=tx 4096 |
| `Tx ring N stopped` | TX queue was paused (ring completely full, driver had to stop accepting) | ring=tx 4096 |

### enic

```bash
ethtool -S eth0 | grep -E 'tx_drop|tx_errors'
```

TX drops are rare on enic when ring is already 4096 (managed at UCS adapter policy).

### i40e

```bash
ethtool -S eth0 | grep -E 'tx_dropped|tx_restart'
```

| Counter | Meaning | Fix |
|---------|---------|-----|
| `tx_dropped` | TX packets the driver couldn't queue | ring=tx 4096 |
| `tx_queue_N_restart` | TX queue was stopped then restarted (temporary ring full) | ring=tx 4096 |

### bnxt_en

```bash
ethtool -S eth0 | grep -E 'tx_discard|tx_error'
```

---

## Additional Counters (TCP, qdisc, OVN)

Beyond NIC and backlog, packets can also be dropped at higher layers:

### TCP retransmissions (indicates upstream drops)

```bash
# TCP-level loss statistics
nstat -z | grep -E 'TcpRetrans|TcpLoss|TcpTimeout'
# Or:
cat /proc/net/snmp | grep Tcp
```

| Field | Meaning |
|-------|---------|
| `TcpRetransSegs` | Total segments retransmitted (something was dropped or delayed) |
| `TcpExtTCPLossProbes` | TLP probes sent (detects tail loss without waiting for full timeout) |
| `TcpExtTCPTimeouts` | Full RTO timeouts (severe — connection stalled for seconds) |

High retransmits on enic workers can indicate the tcp_rmem regression (receiver advertises tiny window → sender stalls → retransmit timers fire).

### Queueing discipline drops (TX output queue)

```bash
tc -s qdisc show dev eth0
```

Shows per-qdisc `dropped` and `overlimits` counts. If the qdisc is dropping packets, the TX output queue is saturated before packets even reach the driver ring. Rare on 10GbE unless traffic shaping is configured.

### Socket-level drops

```bash
ss -s
```

Shows summary: TCP sockets in various states, `drops` count for listening sockets (SYN cookies triggered, accept queue overflow).

```bash
# Per-listening-socket overflow count
ss -tlnp | awk '$2 > 0 {print}'
```

Recv-Q > 0 on a LISTEN socket means connections are waiting in the accept queue — if Recv-Q hits the backlog limit, new connections get RST.

### OVN-Kubernetes / OVS drops (pod network)

```bash
# OVS port statistics (run on node)
ovs-vsctl list-ports br-int
ovs-ofctl dump-ports br-int

# OVS flow table drops
ovs-appctl dpctl/show -s | grep -i drop

# Per-port drops
ovs-vsctl get Interface <port> statistics
```

OVS drops are rare but indicate network policy rejections or OVN-K bugs. If you see drops here but not at NIC level, it's the overlay/policy layer rejecting traffic.

### Netfilter drops (iptables/nftables)

```bash
# Packets dropped by netfilter rules
conntrack -S | grep drop
# Detailed per-chain stats
nft list ruleset | grep -c drop  # or iptables -L -v -n | grep DROP
```

---

## Full Counter Summary — Where Each Type of Loss Shows Up

```
Stage in path              │ Where to see drops              │ What causes them
───────────────────────────┼─────────────────────────────────┼──────────────────────
① NIC hardware (RX)       │ ethtool -S (driver-specific)    │ Ring full, no buffers
② Ring buffer overflow     │ ethtool -S: ring_full,          │ Kernel too slow to drain
                           │   rx_no_bufs, rx_missed         │   → fix: ring=4096
③ IRQ/driver              │ (rarely drops here)             │ Driver bugs only
④ NAPI budget exhausted   │ /proc/net/softnet_stat col 3    │ Budget too small
                           │   (squeeze — not a drop, but    │   → fix: budget/budget_usecs
                           │    causes ring overflow later)  │
⑤ Backlog queue full      │ /proc/net/softnet_stat col 2    │ Queue too small for burst
                           │   (softnet_drops)               │   → fix: netdev_max_backlog
⑥ TCP/IP processing       │ nstat: TcpRetransSegs           │ Window too small (tcp_rmem)
                           │ conntrack -S: insert_failed     │ Conntrack table full
⑦ Socket accept queue     │ ss -tlnp: Recv-Q overflow       │ somaxconn too small
                           │ ss -s: drops on listen sockets  │
⑧ TX qdisc                │ tc -s qdisc show: dropped       │ Output queue saturated
⑨ TX ring full            │ ethtool -S: ring full (TX),     │ NIC can't send fast enough
                           │   tx_dropped, tx_restart        │   → fix: ring=tx 4096
⑩ OVS/OVN overlay         │ ovs-ofctl dump-ports            │ Policy rejection, OVN bug
                           │ ovs-appctl dpctl/show           │
```

---

## Diagnostic Commands (Quick Reference)

| What | Command (via `oc debug node/`) |
|------|------|
| Ring buffer config | `ethtool -g <iface>` |
| Driver drop counters | `ethtool -S <iface>` (driver-specific — see above) |
| Softnet stats | `cat /proc/net/softnet_stat` |
| Generic interface stats | `ip -s link show <iface>` |
| TCP buffer settings | `sysctl net.ipv4.tcp_rmem net.ipv4.tcp_wmem` |
| Active coalesce | `ethtool -c <iface>` |
| Queue/channel count | `ethtool -l <iface>` |
| IRQ distribution | `grep <iface> /proc/interrupts` |
| NIC features (ntuple etc) | `ethtool -k <iface>` |
| Active TuneD profile | `tuned-adm active` |
| Connection backlog | `ss -tlnp` (Recv-Q = pending accepts) |
| TCP memory usage | `cat /proc/net/sockstat` (TCP mem = pages in use) |
| Per-socket buffers | `ss -tm` (skmem field) |
| Conntrack status | `conntrack -S` (insert_failed = table full) |
| Conntrack usage | `sysctl net.netfilter.nf_conntrack_count` vs `nf_conntrack_max` |
