# Parameters

TuneD profile parameters grouped by the **TuneD INI section** that applies them.

| Section | Directory | Mechanism | What it configures |
|---------|-----------|-----------|-------------------|
| [sysctl/](sysctl/) | `[sysctl]` | Writes to `/proc/sys/` via `sysctl` command | All kernel params: `net.*`, `vm.*`, `fs.*`, `kernel.*` |
| [net/](net/) | `[net]` | Runs `ethtool` commands against NIC hardware | Ring buffers, queues, coalescing, NIC features |
| [vm/](vm/) | `[vm]` | Writes to `/sys/kernel/mm/` | Transparent Huge Pages only |
| [cpu/](cpu/) | Boot parameters | Kernel command line (MachineConfig/PerformanceProfile) | C-states, governor |

**Why `net.core.*` sysctls are under `sysctl/`, not `net/`:**

The sysctl namespace prefix (`net.core.*`, `vm.*`) and TuneD section names (`[net]`, `[vm]`) look similar but are different things. A sysctl like `net.core.somaxconn` is a kernel parameter set by writing to `/proc/sys/net/core/somaxconn` — it goes in TuneD's `[sysctl]` section. The TuneD `[net]` section runs `ethtool` to configure NIC hardware (ring buffers, queues) — a completely different mechanism. Similarly, `vm.max_map_count` is a sysctl (`/proc/sys/vm/max_map_count`), while TuneD's `[vm]` section controls THP via `/sys/kernel/mm/`.
