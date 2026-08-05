# paas-node-exporter — ConfigMap-driven Python Prometheus exporter (DaemonSet)

Deploy to OpenShift lab:

```bash
# 1) Build & push image (on bastion with registry access)
cd monitoring/paas-node-exporter
podman build -t <REGISTRY_HOST>:5000/tools/paas-node-exporter:latest .
podman push <REGISTRY_HOST>:5000/tools/paas-node-exporter:latest

# 2) Apply manifests
oc apply -f namespace.yaml
oc apply -f configmap.yaml
oc apply -f daemonset.yaml
oc apply -f service.yaml
oc apply -f serviceMonitor.yaml
oc adm policy add-scc-to-user privileged -z paas-node-exporter -n paas-monitoring
```

| File | Purpose |
|------|---------|
| `exporter.py` | Python collector (`os.popen` + prometheus_client on `:8000/metrics`) |
| `commands` / `configmap.yaml` | Metric command lines mounted at `/app/commands` |
| `daemonset.yaml` | `hostNetwork` + `hostPID`, privileged, host `/sys` + `/host/proc` |
| `service.yaml` | headless Service for scrape target discovery |
| `serviceMonitor.yaml` | UWM scrape `/metrics` every 30s, `matchLabels: paas-node-exporter: "true"` |

Prometheus client serves **`/metrics`** (standard). ServiceMonitor uses that path.
