# [net] Parameters

NIC hardware settings applied via TuneD's `[net]` section using ethtool-style syntax.

```ini
[net]
type=net
devices_udev_regex=^ID_NET_DRIVER=<driver>
ring=rx 4096 tx 4096
channels=combined 16
coalesce=adaptive-rx on adaptive-tx on
features=ntuple on rx-gro-hw on
```

| Parameter | Status | Applies to |
|-----------|--------|-----------|
| [ring](ring/) | Ready | vmxnet3, i40e, bnxt_en |
| [channels](channels/) | Partial (NUMA verification needed) | i40e, bnxt_en |
| [coalesce](coalesce/) | Ready | i40e, bnxt_en |
| [features](features/) | Ready | i40e, bnxt_en (NOT enic) |
| [irq-affinity](irq-affinity/) | Future | — |
