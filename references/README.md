# References

Source material for tuning decisions. KCS articles and cases are accessible to Red Hat employees and customers with active subscriptions.

---

## KCS Articles (Red Hat Knowledgebase)

### Network / NIC Tuning

| ID | Topic |
|----|-------|
| [KCS 5637801](https://access.redhat.com/solutions/5637801) | How to increase ring buffer on OCP 4 (TuneD [net] method) |
| [KCS 1241943](https://access.redhat.com/solutions/1241943) | Tuning netdev_max_backlog and netdev_budget |
| [KCS 387813](https://access.redhat.com/solutions/387813) | Cisco enic rx_no_bufs — UCS adapter policy fix (RSS, ring=4096) |
| [KCS 4049751](https://access.redhat.com/solutions/4049751) | VMware vmxnet3 "ring full" TX drops — increase ring |
| [KCS 5185811](https://access.redhat.com/solutions/5185811) | NIC ring buffer theory and troubleshooting |
| [KCS 62869](https://access.redhat.com/solutions/62869) | Receive Packet Steering (RPS) — software flow steering |
| [KCS 62877](https://access.redhat.com/solutions/62877) | Receive Side Scaling (RSS) — hardware multi-queue |

### Driver-Specific Issues

| ID | Topic |
|----|-------|
| [KCS 7127975](https://access.redhat.com/solutions/7127975) | **CRITICAL** — RHEL 9.4 TCP regression on enic. tcp_rmem must be 3MB. |
| [KCS 2810371](https://access.redhat.com/solutions/2810371) | vmxnet3 ring capped at 4032 with jumbo MTU 9000 |

### Platform / Cluster Operations

| ID | Topic |
|----|-------|
| [KCS 5594111](https://access.redhat.com/solutions/5594111) | etcd heartbeat/election timeout configuration |
| [KCS 4669561](https://access.redhat.com/solutions/4669561) | MCP maxUnavailable — controlling sequential node updates |
| [KCS 6973278](https://access.redhat.com/solutions/6973278) | Disabling THP on OCP via Node Tuning Operator |

---

## Cases (Red Hat Support)

These case numbers can be looked up internally if you have access:

| Case | Topic |
|------|-------|
| 04495863 | NTO tuning best practices — sysctl, ring, THP decisions |
| 03557602 | aRFS / ntuple degradation on enic in OCP |

---

## Additional Reading

- RHEL-97545 — upstream bug tracker for enic TCP auto-tuning regression
- Red Hat PS Router Optimization template — sysctl recommendations for router/infra nodes
- Cisco UCS VIC Tuning Guide — adapter policy configuration for ring/coalesce/channels
