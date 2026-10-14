# Supervisor Service packages

The service definitions downloaded from Broadcom, and our configuration for
them. None of these are applied with kubectl: they are uploaded and
installed in vCenter.

| Service | File | Image source | For the POC |
|---|---|---|---|
| Harbor 2.15.2 | `harbor/supervisor-service-harbor-v2.15.2+vmware.1-vks.1-25639075.yml` | Supervisor depot (`depot.kube-system.svc/...`) | **yes**, with `harbor/harbor-values.yaml` |
| ArgoCD Service 1.2.0 | `argocd/supervisor-service-argocd-1.2.0-25642124.yml` | Supervisor depot | **yes**, then `supervisor/argocd/argocd.yaml` |
| Contour 1.33.5 | `contour/supervisor-service-contour-v1.33.5_vmware.1-25639301.yml` | Supervisor depot | no: only if Harbor is exposed through Contour |
| Velero vSphere Operator 1.8.1 | `velero/velero-vsphere-1.8.1-def.yaml` | `projects.packages.broadcom.com` (internet, via the Supervisor proxy) | no: backup is not in the POC scope |

Reference only (Broadcom's defaults, not used as-is):
`harbor/supervisor-service-harbor-data-values-v2.15.2.yml`,
`contour/contour-data-values-v1.33.5_vmware.1-25639301.yml`.

## What our VCF 9.1 lab runs

| Service | Lab version | Notes |
|---|---|---|
| ArgoCD Service | 1.2.0-25642124, **the same file as here**, from the depot | works; offers ArgoCD 3.4.4 and 3.3.12 |
| Harbor | 2.14.2, bundled with vCenter 9.1 | same settings schema as 2.15.2 (compared field by field), so `harbor-values.yaml` fits both |
| Velero vSphere Operator | 1.9.0, built in | newer than the 1.8.1 file here; prefer the built-in one |
| Contour | not installed | Harbor runs on nginx + LoadBalancer instead |

## Adding and installing a service (vCenter)

1. vCenter > Supervisor Management > Services. If the service and version
   are already listed (Harbor 2.14.2, ArgoCD, Velero on 9.1), skip to step 3.
2. **Add** (new service) or, on an existing service card, **Actions > Add new
   version**: upload the `supervisor-service-*.yml` file.
3. On the service card: **Actions > Install on Supervisors**. Pick the
   Supervisor and the version, and paste the configuration YAML (Harbor:
   the filled-in `harbor-values.local.yaml`; ArgoCD: none).
4. Status: Supervisor > Configure > Supervisor Services > Overview, until
   *Configured*. Each service gets a namespace `svc-<service>-<suffix>`:

   ```sh
   kubectl --context <sv> get ns | grep '^svc-'
   ```

## Depot editions: check before relying on them

These Harbor, ArgoCD and Contour files point at `depot.kube-system.svc/...`:
the Supervisor pulls the service images from its local depot, which must
hold that exact bundle. In our lab the ArgoCD 1.2.0 depot edition installed
fine; a PAIS depot edition did not (validation stopped at Signature
Verification with "Image ... does not exist").

If Harbor 2.15.2 or Contour fails that way at the customer: install the version
vCenter already offers instead (Harbor 2.14.2 on 9.1; `harbor-values.yaml`
works unchanged), or ask the VCF admin to sync the depot.

## Harbor through Contour instead (optional)

Broadcom's default exposes Harbor through Contour. To do it that way:

1. Add and install Contour with `contour-data-values-v1.33.5_vmware.1-25639301.yml`
   (Envoy as a LoadBalancer Service, 2 replicas). Install it **before** Harbor.
2. In `harbor-values.yaml`: `enableContourHttpProxy: true`,
   `enableNginxLoadBalancer: false`.
3. The DNS record for `harbor.customer.local` points at Envoy's VIP instead.

Nothing else in the repo changes.
