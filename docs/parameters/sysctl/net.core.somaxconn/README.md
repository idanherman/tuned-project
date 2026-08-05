# net.core.somaxconn

## What it controls

The maximum length of the listen backlog queue for any socket. When a server calls `listen(fd, backlog)`, the effective backlog is capped at `somaxconn`. Controls how many completed TCP connections can wait in the accept queue before the kernel starts dropping SYNs.

## TuneD syntax

```ini
[sysctl]
net.core.somaxconn = 10240
```

Check current value:
```bash
sysctl net.core.somaxconn
```

## Default

4096 (RHEL 9.x)

## Legacy issue

A common finding: `somaxconn = 655535` — a typo carried over from the RHEL 7 era (intended value was likely 65535). This was set on all node roles indiscriminately.

## Per-role decisions

| Role | Value | Rationale |
|------|-------|-----------|
| Infra / Router | **10240** | Per RH Performance Scaling Guide for HAProxy/router pods |
| All others | **4096** (remove override) | Default is sufficient; no benefit from higher values on non-listener nodes |

## Relationship to HAProxy maxconn

`somaxconn` does **not** need to match HAProxy's `maxconn` setting. They serve different purposes:

- `somaxconn` — kernel-level cap on the accept queue depth
- `maxconn` — HAProxy-level cap on total concurrent connections

HAProxy drains the accept queue rapidly. A `somaxconn` of 10240 provides headroom for SYN bursts without being wasteful. Setting it to 655535 provides no benefit and wastes kernel memory for backlog structures.

## References

- [Article 3428361](https://access.redhat.com/articles/3428361) — OpenShift router performance tuning
- [Article 5638361](https://access.redhat.com/articles/5638361) — HAProxy scaling recommendations
- Case 04495863 Q3 — somaxconn review and correction
