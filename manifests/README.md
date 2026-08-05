# Tuned CR Manifests

Deployable Node Tuning Operator manifests. One `Tuned` CR per profile for independent lifecycle management.

## Apply Order

For initial deployment, apply in this order:

1. **Workers first** (no drain needed for sysctl-only changes):
   ```bash
   oc apply -f baremetal-cisco-enic.yaml
   oc apply -f baremetal-cisco-i40e.yaml      # only when hardware available
   oc apply -f baremetal-dell-r6625.yaml      # only when hardware available
   oc apply -f vm-worker.yaml
   ```

2. **Infra nodes** (no drain needed):
   ```bash
   oc apply -f vm-infra.yaml
   ```

3. **Control-plane** (sequential label-gating — see below):
   ```bash
   oc apply -f vm-control-plane.yaml
   # then label one master at a time (see rollout procedure below)
   ```

## Sequential Control-Plane Rollout

The `vm-control-plane` CR requires an additional gating label `tuning.custom/ring-resize=true`. This enables sequential application:

```bash
# 1. Apply the CR (no nodes match yet — nobody has the gating label)
oc apply -f vm-control-plane.yaml

# 2. Label first master
oc label node <master-0> tuning.custom/ring-resize=true

# 3. Wait for TuneD to apply (watch profile switch)
oc get pods -n openshift-cluster-node-tuning-operator -l openshift-app=tuned \
  -o wide | grep <master-0>
# Check logs:
oc logs -n openshift-cluster-node-tuning-operator <tuned-pod-on-master-0> | tail -20

# 4. Verify etcd health
oc get etcd -o jsonpath='{.items[0].status.conditions[?(@.type=="EtcdMembersAvailable")].message}'

# 5. Wait 30s for etcd stabilization, then repeat for next master
oc label node <master-1> tuning.custom/ring-resize=true
# ... verify ... repeat for master-2

# 6. AFTER all masters are stable: remove the gating label requirement
#    Edit vm-control-plane.yaml to remove the tuning.custom/ring-resize match line
#    Then re-apply. This makes future masters auto-match without manual gating.
```

## Verification

After applying all manifests:
```bash
../scripts/validate-tuning.sh
```

## Reverting

To revert a single profile:
```bash
oc delete tuned <cr-name> -n openshift-cluster-node-tuning-operator
```
NTO will automatically reapply the next matching profile (built-in `openshift-node` at priority 40).
