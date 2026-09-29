# [sysctl] Parameters

Kernel parameters applied via TuneD's `[sysctl]` section. These map directly to `/proc/sys/` paths.

```ini
[sysctl]
net.core.somaxconn = 10240
net.ipv4.tcp_rmem = 4096 3145728 6291456
```

| Parameter | Status | Applies to |
|-----------|--------|-----------|
| [net.core.netdev_budget](net.core.netdev_budget/) | Ready | BM only |
| [net.core.netdev_max_backlog](net.core.netdev_max_backlog/) | Ready | BM only |
| [net.core.rmem_max](net.core.rmem_max/) | No change | BM (already set) |
| [net.ipv4.tcp_rmem](net.ipv4.tcp_rmem/) | CRITICAL | enic only |
| [net.core.somaxconn](net.core.somaxconn/) | Ready | Infra only |
| [net.ipv4.tcp_max_syn_backlog](net.ipv4.tcp_max_syn_backlog/) | Ready | Infra only |
| [fs.file-max](fs.file-max/) | Ready | Infra only |
| [net.ipv4.ip_local_port_range](net.ipv4.ip_local_port_range/) | Ready | Infra only |
| [vm.max_map_count](vm.max_map_count/) | Ready | Infra only |
| [kernel.printk](kernel.printk/) | Low priority | All nodes |
| [net.netfilter.nf_conntrack_max](net.netfilter.nf_conntrack_max/) | Future | — |
| [net.ipv4.tcp_slow_start_after_idle](net.ipv4.tcp_slow_start_after_idle/) | Future | — |
| [net.ipv4.tcp_no_metrics_cache](net.ipv4.tcp_no_metrics_cache/) | Recommended | enic (with tcp_rmem fix) |
| [net.ipv4.tcp_tw_reuse](net.ipv4.tcp_tw_reuse/) | Recommended | Infra/router |
| [net.ipv4.tcp_keepalive](net.ipv4.tcp_keepalive/) | Medium priority | BM (iSCSI), all |
| [net.core.dev_weight](net.core.dev_weight/) | Under investigation | BM |
