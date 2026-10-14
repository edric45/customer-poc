# Where the proxy is set

The customer's environment reaches the internet only through a proxy. There is no
single switch: every layer that downloads something has its own setting.

Labels: **lab** = seen on our VCF 9.1 lab (which has no proxy, so the
settings exist and validate, but the traffic was not tested); **documented** =
Broadcom docs; **unverified** = to confirm at the customer.

| Layer | What goes out | Where it is set | In this repo |
|---|---|---|---|
| vCenter | content library (VKr node images), Supervisor Service and depot downloads | vCenter appliance management (VAMI, port 5480) > Networking > Proxy settings | no (UI) |
| Supervisor | image pulls by the Supervisor and vSphere Pods from internet registries | vCenter > Supervisor Management > Supervisors > *Supervisor* > Configure > Network > Proxy: inherit from vCenter, own settings, or none | no (UI) |
| Harbor (Supervisor Service) | proxy-cache projects (Docker Hub...), replication, Trivy DB | `proxy:` in the service configuration | `supervisor/services/harbor/harbor-values.yaml` (lab: field exists) |
| ArgoCD (Supervisor Service) | git clone, Helm charts | `spec.repo.proxy`, `spec.applicationSet.proxy`, `spec.server.proxy` | `supervisor/argocd/argocd.yaml` (lab: dry-run passes) |
| VKS cluster nodes | containerd image pulls, kubelet | Cluster variable `osConfiguration.systemProxy` (`http`, `https`, `noProxy[]`) | `supervisor/clusters/*/cluster.yaml` (lab: dry-run passes) |
| Pods in a cluster | whatever the app calls | the app's own `HTTP_PROXY` / `HTTPS_PROXY` / `NO_PROXY` env | per app |
| Your workstation | `vcf`, `kubectl`, `argocd` CLIs | `NO_PROXY` must cover the Supervisor, cluster VIPs and ArgoCD | no |

Notes:

- **Supervisor Service images.** Where a service's images come from is in
  its package file (`supervisor/services/`):
  - `mgmt-image-proxy.kube-system...` (Harbor 2.14.2 bundled with vCenter 9.1)
    or `depot.kube-system.svc/...` (the Harbor 2.15.2, ArgoCD 1.2.0 and
    Contour files here): served inside the Supervisor, no proxy involved.
  - `projects.packages.broadcom.com/...` (the Velero 1.8.1 file): the
    internet, so the Supervisor proxy must be set.
- **Clusters inheriting the Supervisor proxy.** Older TKG releases copied the
  Supervisor's proxy into new clusters. Whether `builtin-generic-v3.7.0` does
  is **unverified**, so the clusters here set `systemProxy` explicitly.
- **Node proxy is not pod proxy.** `systemProxy` reaches containerd and
  kubelet only. VKS add-ons are installed from the Supervisor's own package
  depot (each cluster has a `depot.kube-system.svc` add-on, lab), so they
  should not need the internet; any image an app pulls from the internet does,
  through containerd and therefore through the proxy.

## noProxy: what must bypass the proxy

A missing entry fails quietly: image pulls from Harbor sent to the proxy
(which cannot reach it, or refuses the internal CA), API calls to the
Supervisor refused. For the cluster nodes:

| Entry | Why |
|---|---|
| `localhost`, `127.0.0.1` | local components |
| `.svc`, `.svc.cluster.local`, `.cluster.local` | in-cluster services |
| service CIDR, pod CIDR (the Cluster's `clusterNetwork`) | in-cluster traffic by IP |
| Harbor's FQDN (and its domain) | image pulls must go direct, with the trusted CA |
| the internal DNS domain (`.customer.local`) | vCenter, git, anything internal |
| VPC / namespace networks | node IPs, LoadBalancer VIPs, the cluster's own API VIP |
| Supervisor management network | Supervisor API, vCenter |

Matching rules (from the ClusterClass field description): a domain matches
itself and its subdomains (`.customer.local` or `customer.local`); CIDRs only match
connections made **by IP**, never names. A single `*` disables the proxy.

## Check at the customer

```sh
# node proxy as containerd sees it (from a node, via SSH; README, troubleshooting)
sudo systemctl show containerd --property=Environment

# image pulls, in a throwaway namespace ("restricted", the VKS default,
# rejects a plain kubectl run)
kubectl create namespace pull-test
kubectl label namespace pull-test pod-security.kubernetes.io/enforce=baseline
# from Harbor: must go DIRECT (noProxy) with Harbor's CA trusted
kubectl -n pull-test run from-harbor --image=harbor.customer.local/library/nginxinc/nginx-unprivileged:1.27-alpine \
  --restart=Never --command -- sleep 60
# from the internet: must go THROUGH the proxy
kubectl -n pull-test run from-internet --image=docker.io/library/busybox:1.37 \
  --restart=Never --command -- sleep 60
kubectl -n pull-test get pods                      # both Running
kubectl -n pull-test describe pods | grep -E 'Failed|x509|timeout|proxy'
kubectl delete namespace pull-test
```
