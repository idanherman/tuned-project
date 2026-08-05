#!/usr/bin/env python3
"""Command-driven Prometheus node exporter (ConfigMap-based).

Reads lines: interval,metric_name,command,func_bool
Runs each command via os.popen on an interval and exposes gauges on :8000/metrics.
"""

from __future__ import annotations

import os
import threading
import time

from prometheus_client import Gauge, start_http_server

COMMAND_FILE_LOC = os.environ.get("COMMAND_FILE_LOC", "/app/commands")
METRICS_PORT = int(os.environ.get("METRICS_PORT", "8000"))
HOSTNAME_PATH = os.environ.get(
    "HOSTNAME_PATH", "/host/proc/sys/kernel/hostname"
)


def node_name() -> str:
    try:
        with open(HOSTNAME_PATH, encoding="utf-8") as fh:
            return fh.read().strip() or os.uname().nodename
    except OSError:
        return os.uname().nodename


NODE = node_name()


def parse_command_string(line: str):
    """ConfigMap line parser: interval,name,command,...,func.

    Command may contain commas; middle fields are rejoined.
    """
    elements = [p.strip() for p in line.strip().split(",")]
    if len(elements) < 4:
        raise ValueError(f"bad command line (need 4 fields): {line!r}")
    interval = int(elements[0])
    gauge_name = elements[1]
    command = ",".join(elements[2:-1])
    func = elements[-1].lower() == "true"
    return interval, gauge_name, command, func


def load_commands(path: str):
    commands = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            commands.append(parse_command_string(line))
    return commands


def act(interval: int, gauge_name: str, command: str, func: bool, gauge: Gauge):
    while True:
        try:
            out = os.popen(command).read().strip()
            if func:
                # String mode: value=1, payload in label
                gauge.labels(node_name=NODE, data=out[:200] if out else "").set(1)
            else:
                value = float(out.splitlines()[-1]) if out else 0.0
                gauge.labels(node_name=NODE).set(value)
        except Exception as exc:  # noqa: BLE001 — keep collector alive
            print(f"error {gauge_name}: {exc}", flush=True)
            try:
                if not func:
                    gauge.labels(node_name=NODE).set(0)
            except Exception:  # noqa: BLE001
                pass
        time.sleep(interval)


def main():
    print(f"node={NODE} commands={COMMAND_FILE_LOC} port={METRICS_PORT}", flush=True)
    commands = load_commands(COMMAND_FILE_LOC)
    if not commands:
        raise SystemExit(f"no commands loaded from {COMMAND_FILE_LOC}")

    start_http_server(METRICS_PORT)
    threads = []
    for interval, gauge_name, command, func in commands:
        if func:
            gauge = Gauge(gauge_name, gauge_name, ["node_name", "data"])
        else:
            gauge = Gauge(gauge_name, gauge_name, ["node_name"])
        t = threading.Thread(
            target=act,
            args=(interval, gauge_name, command, func, gauge),
            daemon=True,
            name=gauge_name,
        )
        t.start()
        threads.append(t)
        print(f"started {gauge_name} every {interval}s", flush=True)

    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
