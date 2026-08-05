# Scripts

## collect-nic-diagnostics.sh

Run from bastion. Collects per-node NIC health metrics via `oc debug node/`.
Outputs CSV with one row per node/interface.

Usage:
```bash
./collect-nic-diagnostics.sh
```

Collects: ring buffers, queues, driver-specific drop counters, softnet_stat, sysctl values (including tcp_rmem, tcp_wmem, somaxconn, netdev_budget_usecs), THP state, active TuneD profile, and node uptime for drop-rate calculation.

Output includes:
- Summary of nodes with non-zero drops/errors
- Ring buffer utilization table (current vs max)
- **Drop rate estimates** (drops/hour based on uptime) with severity classification

## validate-tuning.sh

Run after applying Tuned CRs. Validates that profiles are correctly applied.

Usage:
```bash
./validate-tuning.sh
```

Checks:
1. **Label verification** — bare-metal nodes have `node.kubernetes.io/nic-driver` label
2. **Profile assignment** — each node's active TuneD profile matches expected
3. **Critical sysctls** — tcp_rmem, somaxconn, backlog, THP, budget_usecs
4. **Ring buffers** — all NICs at maximum ring size

Exit code 0 = all passed, 1 = failures detected.

## QR encode/decode

For air-gapped data extraction. See `diagnostics/` for collected data.
