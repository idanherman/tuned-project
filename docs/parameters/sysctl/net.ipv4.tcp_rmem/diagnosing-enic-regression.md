# Diagnosing the enic TCP Auto-Tuning Regression (RHEL-97545)

Step-by-step procedure to detect whether a node is affected by the enic receive window regression.

## Quick test

From an enic-attached node, download a large file and check throughput:

```bash
curl -o /dev/null http://<known-fast-server>/largefile.bin
```

- **Expected (healthy):** 100+ MB/s on 10GbE
- **Affected:** ~1–5 MB/s despite 10GbE link and no packet drops

If throughput is an order of magnitude below expected, proceed with the checks below.

## Step 1: Confirm NIC driver is enic

```bash
ethtool -i <iface> | grep driver
# driver: enic
```

If the driver is not `enic`, this regression does not apply.

## Step 2: Check kernel version

```bash
uname -r
```

- **5.14.0-427.x** = RHEL 9.4 kernel = **affected**
- OCP 4.16.x ships this kernel = **affected**
- Earlier kernels (RHEL 9.3 / OCP 4.15) = not affected
- Later kernels with the fix backported = not affected

## Step 3: Check if the fix is installed

```bash
rpm -q --changelog kernel | grep RHEL-97545
```

- If no output → fix is **not** present → node is **affected**
- If a changelog entry mentioning RHEL-97545 appears → fix is present

## Step 4: Confirm receive window is stuck

```bash
ss -ti dst <remote-ip> | grep -E 'rcv_space|rcv_ssthresh'
```

On a healthy connection after transferring data, `rcv_space` should grow well beyond 128 KB. If it's stuck near 131072 (128 KB), auto-tuning is broken.

## Decision tree

```
Is the NIC driver enic?
├── No  → NOT affected (stop here)
└── Yes
    └── Is the kernel 5.14.0-427.x (RHEL 9.4)?
        ├── No  → likely NOT affected
        └── Yes
            └── Does `rpm -q --changelog kernel | grep RHEL-97545` return output?
                ├── Yes → fix is present, NOT affected
                └── No  → AFFECTED — apply tcp_rmem workaround
```

## Workaround

Apply via TuneD `[sysctl]` section on all enic nodes:

```ini
net.ipv4.tcp_rmem = 4096 3145728 6291456
net.ipv4.tcp_wmem = 4096 3145728 6291456
```

This sets the initial receive buffer to 3 MB, ensuring adequate throughput even when auto-tuning fails to grow the window.
