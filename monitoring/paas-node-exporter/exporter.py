#!/usr/bin/env python3
"""ConfigMap-driven Prometheus node exporter (DaemonSet).

Reads command lines from a ConfigMap-mounted file and exposes metrics on :8000/metrics.

Line format: interval,metric_name,command,mode
Modes:
  False  — command outputs a single numeric value; labels: [node_name]
  True   — command outputs a string; value=1, string in 'data' label: [node_name, data]
  Device — command outputs 'device_name value' per line; labels: [node_name, device]
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

MODE_SINGLE = "single"
MODE_STRING = "string"
MODE_DEVICE = "device"


def node_name() -> str:
    try:
        with open(HOSTNAME_PATH, encoding="utf-8") as fh:
            return fh.read().strip() or os.uname().nodename
    except OSError:
        return os.uname().nodename


NODE = node_name()


def parse_command_string(line: str):
    """ConfigMap line parser: interval,name,command,...,mode.

    Command may contain commas; middle fields are rejoined.
    """
    elements = [p.strip() for p in line.strip().split(",")]
    if len(elements) < 4:
        raise ValueError(f"bad command line (need 4 fields): {line!r}")
    interval = int(elements[0])
    gauge_name = elements[1]
    command = ",".join(elements[2:-1])
    mode_raw = elements[-1].lower()
    if mode_raw == "true":
        mode = MODE_STRING
    elif mode_raw == "device":
        mode = MODE_DEVICE
    else:
        mode = MODE_SINGLE
    return interval, gauge_name, command, mode


def load_commands(path: str):
    commands = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            commands.append(parse_command_string(line))
    return commands


def act(interval: int, gauge_name: str, command: str, mode: str, gauge: Gauge):
    """Collector loop: run command, parse output, update gauge."""
    seen_devices: set[str] = set()

    while True:
        try:
            out = os.popen(command).read().strip()

            if mode == MODE_STRING:
                gauge.labels(node_name=NODE, data=out[:200] if out else "").set(1)

            elif mode == MODE_DEVICE:
                current_devices: set[str] = set()
                for line in out.splitlines():
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        device = parts[0]
                        try:
                            value = float(parts[1])
                        except ValueError:
                            continue
                        gauge.labels(node_name=NODE, device=device).set(value)
                        current_devices.add(device)
                # Remove stale devices (NIC removed/renamed)
                for stale in seen_devices - current_devices:
                    try:
                        gauge.remove(NODE, stale)
                    except Exception:
                        pass
                seen_devices = current_devices

            else:
                value = float(out.splitlines()[-1]) if out else 0.0
                gauge.labels(node_name=NODE).set(value)

        except Exception as exc:  # noqa: BLE001
            print(f"error {gauge_name}: {exc}", flush=True)
            try:
                if mode == MODE_SINGLE:
                    gauge.labels(node_name=NODE).set(0)
            except Exception:
                pass

        time.sleep(interval)


def main():
    print(f"node={NODE} commands={COMMAND_FILE_LOC} port={METRICS_PORT}", flush=True)
    commands = load_commands(COMMAND_FILE_LOC)
    if not commands:
        raise SystemExit(f"no commands loaded from {COMMAND_FILE_LOC}")

    start_http_server(METRICS_PORT)
    threads = []
    for interval, gauge_name, command, mode in commands:
        if mode == MODE_STRING:
            gauge = Gauge(gauge_name, gauge_name, ["node_name", "data"])
        elif mode == MODE_DEVICE:
            gauge = Gauge(gauge_name, gauge_name, ["node_name", "device"])
        else:
            gauge = Gauge(gauge_name, gauge_name, ["node_name"])
        t = threading.Thread(
            target=act,
            args=(interval, gauge_name, command, mode, gauge),
            daemon=True,
            name=gauge_name,
        )
        t.start()
        threads.append(t)
        print(f"started {gauge_name} every {interval}s mode={mode}", flush=True)

    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()
