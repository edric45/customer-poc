# A VKS cluster with Cilium instead of Antrea

File: `supervisor/clusters/customer-cilium-01/cluster.yaml`.

Labels: **lab** = checked on our VCF 9.1 lab; **unverified** = to test.
No Cilium cluster has been built in our lab yet.

## How

The ClusterClass `builtin-generic-v3.7.0` has a variable `bootstrapAddons`
(lab). Its `cniRef` names the CNI add-on installed while the cluster
bootstraps:

```yaml
- name: bootstrapAddons
  value:
    cniRef:
      name: cilium
      namespace: vmware-system-vks-public
```

| Fact | Source |
|---|---|
| Cilium is a VKS add-on, release `cilium.kubernetes.vmware.com.1.19.4-vmware.1-vks.1` | lab |
| `bootstrapAddons` needs Kubernetes 1.35+, and "cannot be updated after creation" | lab, ClusterClass schema |
| Every existing cluster in the lab shows `cniRef: antrea` (the default) | lab |
| A Cluster with `cniRef: cilium` passes server dry-run | lab |
| The cluster actually comes up with Cilium | **unverified** |

So the CNI is chosen once. An Antrea cluster cannot be switched to Cilium;
build a new one and move the workloads.

```sh
# releases on offer
kubectl -n vmware-system-vks-public get addonreleases | grep cilium
# settings the add-on accepts
kubectl -n vmware-system-vks-public get addonconfigdefinition \
  cilium.kubernetes.vmware.com.1.19.4---vmware.1-vks.1 -o yaml
```

## Settings the add-on exposes (1.19.4, lab)

| Setting | Default | Note |
|---|---|---|
| `hubble.enabled` | true | flow data collected on each node |
| `hubble.relay.enabled`, `hubble.ui.enabled` | false | needed to SEE flows (Hubble UI, `hubble observe`) |
| `hubble.metrics.enabled` | false | per-flow Prometheus metrics |
| `policyEnforcementMode` | default | `always` = default-deny everywhere |
| `l7Proxy` | false | L7 (HTTP, FQDN/DNS) network policies need it |
| `gatewayAPI.enabled`, `ingressController.enabled` | false | Cilium's own ingress; we use Istio instead |
| `egressGateway.enabled` + `bpf.masquerade` | false | Cilium's egress gateway (both required) |
| `MTU` | 0 (auto) | |

There is no `kubeProxyReplacement` setting; kube-proxy stays on (the file
leaves `kubeProxyConfiguration.enabled` at its default, true).

**Changing these values** (e.g. turning on Hubble UI): VKS creates an
AddonConfig `customer-cilium-01-cilium` in customer-ns for the CNI, as it does
`<cluster>-antrea` for Antrea clusters (lab). Editing its `spec.values` is
the likely way; whether VKS keeps the edit or resets it is **unverified**.
Test after the cluster is up:

```sh
kubectl -n customer-ns get addonconfig customer-cilium-01-cilium -o yaml
```

## Check it runs Cilium

```sh
kubectl --context customer-cilium-01 -n kube-system get pods -l k8s-app=cilium -o wide
kubectl --context customer-cilium-01 -n kube-system exec ds/cilium -- cilium-dbg status --brief
kubectl --context customer-cilium-01 -n kube-system get pods | grep -i antrea   # nothing
```

## What changes compared to Antrea

| | Antrea (default) | Cilium |
|---|---|---|
| NSX integration | Antrea-NSX (pod policies and Traceflow from NSX), Antrea Egress with NSX VPC subnets (lab-tested) | none of these |
| Observability | Antrea Traceflow, flow exporter not exposed by the VKS add-on | Hubble (flows per pod, DNS, drops) once relay/UI are on |
| Policy | Kubernetes NetworkPolicy + Antrea policies | Kubernetes NetworkPolicy + CiliumNetworkPolicy (L7 and FQDN with `l7Proxy`) |
| Istio CNI | works (lab) | **risk**: upstream Istio says Cilium needs `cni.exclusive=false` for the Istio CNI plugin to stay installed, and the VKS add-on does not expose it. Test Istio sidecar injection early on this cluster. |

## Suggested test at the customer

1. Create `customer-cilium-01`; check the commands above.
2. Install the istio and cert-manager add-ons for it (copy
   `supervisor/clusters/customer-cluster-01/addons/` with the names changed), and
   check a meshed pod starts (Istio CNI risk above).
3. Turn on Hubble relay and UI in the AddonConfig; check the change sticks.
