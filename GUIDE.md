# Customer VKS POC: master guide

Start here. This page gives the installation order, where each step is
done, which files and documents belong to it, and how to tell it worked.
The step-by-step commands are in `README.md`; the topics it relies on are in
`docs/`. Everything is customer-neutral: names say `customer`, and
"Renaming for a real customer" below swaps them in one pass.

**Scope.** On a VCF 9.1 Supervisor with NSX VPC networking and an outbound
proxy:
- a regional Harbor and ArgoCD, both Supervisor Services;
- a VKS cluster that trusts Harbor and uses the proxy;
- add-ons managed by ArgoCD (cert-manager, Istio, Headlamp);
- an Istio Gateway API ingress with Grafana and a sample app behind it;
- optionally, a second cluster on Cilium.

**Source labels used in every document:** **lab** = seen on our VCF 9.1 lab,
**documented** = Broadcom or upstream docs, **unverified** = to confirm at the
customer.

## 1. The picture

```
 jump host (kubectl, vcf, argocd, docker)           git (this repo)
        |                                                 |
        v                                                 v
 vCenter / Supervisor (VCF 9.1, NSX VPC)                  |
   Supervisor Services                                    |
     Harbor  (regional registry, LB VIP)  <-- images      |
     ArgoCD  (in vSphere Namespace customer-ns) <---------+  reads git
   customer-ns                                            |
     Cluster customer-cluster-01 ------------------------ applied by ArgoCD (manual sync)
     AddonInstall/AddonConfig: cert-manager, istio, headlamp (ApplicationSet)
        |
        v   VKS builds and configures
 customer-cluster-01 (VKS, Antrea; node proxy; trusts Harbor automatically)
   istio-system         Istio (sidecar mode, Gateway API class "istio")
   customer-gateway     shared Gateway *.apps.customer.local  (one VIP)
   grafana              Grafana (Helm chart)   -> https://grafana.apps.customer.local
   sample-app           sample app             -> https://sample.apps.customer.local
   headlamp             Headlamp + own Gateway -> https://headlamp.customer.local
   tanzu-system-monitoring  Prometheus (installed by VKS by default)
```

## 2. Installation order

Do the phases in order: each one needs the previous ones.

| # | Phase | Where it is done | Instructions | Files used | Supporting docs | Done when |
|---|---|---|---|---|---|---|
| 0 | Jump host tools | jump host shell | README Step 0 | none | `docs/jumphost.md` (all), `docs/proxy.md` (section on the workstation) | `kubectl version`, `vcf version`, `argocd version --client`, `docker version` all answer; Supervisor reachable |
| 1 | Supervisor ready | vCenter UI | README Step 1 | none | `docs/proxy.md` (vCenter and Supervisor rows) | `kubectl -n customer-ns get virtualmachineclass,storageclass` lists the classes; the release and ClusterClass in `cluster.yaml` exist |
| 2 | Regional Harbor | vCenter UI + jump host | README Step 2 | `supervisor/services/harbor/*`, `scripts/images.txt`, `scripts/mirror-images.sh` | `supervisor/services/README.md`, `docs/harbor-trust.md` (sections 2, 3) | `https://harbor.customer.local/api/v2.0/ping` answers Pong without `-k`; images pushed |
| 3 | ArgoCD + Supervisor + repo | vCenter UI, then kubectl and argocd CLI | README Step 3 (3.1 to 3.4) | `supervisor/services/argocd/*`, `supervisor/argocd/argocd.yaml` | `docs/git-repos.md`, `supervisor/services/README.md` | `argocd cluster list` shows `supervisor`; `argocd repo list` shows Successful |
| 4 | Workload cluster | argocd CLI (manual sync), then vcf and argocd CLI | README Step 4 (4.1 to 4.4) | `supervisor/applications/customer-cluster-01.yaml`, `supervisor/clusters/customer-cluster-01/cluster.yaml` | `docs/proxy.md`, `docs/harbor-trust.md` (section 4), `docs/commands.md` (section 3) | Cluster AVAILABLE True; `kubectl get nodes` all Ready; `argocd cluster list` shows `customer-cluster-01` |
| 5 | Add-ons | kubectl on the Supervisor (ApplicationSet) | README Step 5 | `supervisor/applicationsets/customer-cluster-01-addons.yaml`, `supervisor/clusters/customer-cluster-01/addons/*` | `docs/commands.md` (section 4) | `argocd app list -l kind=vks-addon`: three apps Synced/Healthy; pods in cert-manager, istio-system, headlamp |
| 6 | Gateway, Grafana, sample app | kubectl on the Supervisor (Applications + ApplicationSet) | README Step 6 (6.1 to 6.3) | `supervisor/applications/customer-cluster-01-platform.yaml`, `supervisor/applications/customer-cluster-01-grafana.yaml`, `supervisor/applicationsets/customer-cluster-01-apps.yaml`, `customer-cluster-01/**` | `docs/commands.md` (sections 5, 7) | the three URLs answer over HTTPS; Grafana shows the Kubernetes dashboards with data |
| 7 | Cilium cluster (optional) | kubectl on the Supervisor | README Step 7 | `supervisor/clusters/customer-cilium-01/cluster.yaml` | `docs/cilium.md` | `cilium-dbg status` OK; meshed pod starts (Istio CNI risk) |

DNS records the customer must create along the way:

| Name | Points at | When |
|---|---|---|
| `harbor.customer.local` | Harbor's LoadBalancer IP (Service `harbor-nginx`) | phase 2 |
| `*.apps.customer.local` | shared gateway ADDRESS (`customer-gateway`) | phase 6 |
| `headlamp.customer.local` | Headlamp gateway ADDRESS | phase 5/6 |

Secrets created by hand, never in git: the Harbor values copy
(`harbor-values.local.yaml`), the git token in ArgoCD, the `grafana-admin`
Secret, Harbor robot accounts.

## 3. Where to find what

| Topic | Where |
|---|---|
| Step-by-step runbook | `README.md`, Steps 0 to 7 |
| Repo layout, placeholders to change | `README.md`, "Layout" and "Values to set for the customer" |
| Installing CLIs and Docker behind a proxy | `docs/jumphost.md` |
| Every place the proxy is set; noProxy contents | `docs/proxy.md` |
| Supervisor Service packages (Harbor, ArgoCD, Contour, Velero): which to use, how to add | `supervisor/services/README.md` |
| Harbor configuration | `supervisor/services/harbor/harbor-values.yaml` (comments explain each setting) |
| Harbor certificate: extract, verify, trust everywhere | `docs/harbor-trust.md` |
| Copying public images into Harbor | `scripts/mirror-images.sh` (header lists the settings), `scripts/images.txt` |
| ArgoCD instance settings (version, proxy, ApplicationSets) | `supervisor/argocd/argocd.yaml` |
| Adding the Supervisor and clusters to ArgoCD | `README.md` 3.3 and 4.4 |
| Adding a private GitHub/GitLab repo to ArgoCD | `docs/git-repos.md` |
| Applications vs ApplicationSets, how to add them | `README.md`, "ArgoCD reference" |
| Cluster definition (proxy, CA trust, CNI, pools) | `supervisor/clusters/customer-cluster-01/cluster.yaml` |
| Cluster with Cilium | `supervisor/clusters/customer-cilium-01/cluster.yaml`, `docs/cilium.md` |
| VKS add-ons (one folder each) | `supervisor/clusters/customer-cluster-01/addons/` |
| Shared Istio gateway and certificate | `customer-cluster-01/platform/gateway.yaml` |
| Pod Security fix for gateway pods | `customer-cluster-01/platform/istio-gatewayclass-defaults.yaml` |
| Headlamp login account | `customer-cluster-01/platform/headlamp-admin.yaml` |
| Grafana (chart, values, dashboards) | `supervisor/applications/customer-cluster-01-grafana.yaml`, `customer-cluster-01/monitoring/` |
| Sample app (template for onboarding apps) | `customer-cluster-01/apps/sample-app/` |
| Status, sync, refresh, logs, troubleshooting | `docs/commands.md`, and `README.md` "Troubleshooting" |
| Cleanup | `README.md`, "Cleanup" |

## 4. Open items to verify at the customer

Not testable in our lab (no proxy there, Avi instead of the NSX LB), or
never built there:

1. All proxy traffic: nodes, Harbor, ArgoCD, Grafana's dashboard download
   (`docs/proxy.md`, "Check at the customer").
2. Automatic Harbor trust by VKS clusters (documented; our lab Harbor lacks
   the label): test in `docs/harbor-trust.md` section 4.
3. Depot editions of the Harbor 2.15.2 and Contour packages: fall back to
   the Harbor version vCenter offers (`supervisor/services/README.md`).
4. Whether clusters inherit the Supervisor proxy (we set it explicitly
   anyway).
5. A Cilium cluster coming up, Istio CNI on Cilium, editing the Cilium
   AddonConfig (`docs/cilium.md`).
6. `scripts/mirror-images.sh` against a real Harbor (dry-run tested only).
7. Docker Hub's anonymous pull limit behind one proxy address; Harbor
   proxy cache as the fix (README Step 2).

## 5. Renaming for a real customer

All customer-specific names are tokens. Replace them across the repo, then
rename the folders that carry them. Run from the repo root on the jump host
(GNU sed); set the values first:

```sh
NAME=acme                   # short name, lowercase, dashes only
DOMAIN=acme.internal        # internal DNS domain
GIT=https://gitlab.acme.internal/platform/acme-poc.git

grep -rl --exclude-dir=.git -e customer . | xargs sed -i \
  -e "s#https://git.customer.local/platform/customer-poc.git#$GIT#g" \
  -e "s#customer\.local#$DOMAIN#g" \
  -e "s#customer-ns#$NAME-ns#g" \
  -e "s#customer-cluster-01#$NAME-cluster-01#g" \
  -e "s#customer-cilium-01#$NAME-cilium-01#g" \
  -e "s#customer-gateway#$NAME-gateway#g" \
  -e "s#customer-apps#$NAME-apps#g" \
  -e "s#customer-poc#$NAME-poc#g" \
  -e "s#harbor-customer#harbor-$NAME#g" \
  -e "s#argocd-customer#argocd-$NAME#g"

mv customer-cluster-01 $NAME-cluster-01
mv supervisor/clusters/customer-cluster-01 supervisor/clusters/$NAME-cluster-01
mv supervisor/clusters/customer-cilium-01 supervisor/clusters/$NAME-cilium-01
for f in supervisor/applications/customer-* supervisor/applicationsets/customer-*; do mv "$f" "${f/customer-/$NAME-}"; done

grep -rn --exclude-dir=.git -e 'customer-' -e 'customer\.' .   # what's left is prose ("the customer"), fine
```

Then the remaining values in README "Values to set for the customer"
(proxy URL, noProxy CIDRs, storage policy, VM classes, release).

## 6. Building one complete document from this repo

For whoever (or whichever assistant) turns this repo into a single
installation document:

1. **Order:** follow section 2 of this guide, phase by phase. For each phase
   take the README step as the backbone and insert the supporting doc
   sections listed in the same table row where the step refers to them.
   Order of the docs when a phase uses several: jumphost, services README,
   harbor-trust, git-repos, proxy, commands, cilium.
2. **Front matter:** this guide's sections 1 (picture), 2 (order, DNS
   records, secrets) and README "Values to set for the customer".
3. **Commands and YAML verbatim:** copy command blocks and manifests exactly;
   do not reformat, shorten or "fix" them. Keep comments inside YAML: they
   carry the reasons.
4. **Keep the source labels** (lab / documented / unverified) next to the
   statements they belong to, and keep the warnings (manual sync of the
   Cluster, never `--force` it, never `delete addonconfig --all`, secrets
   out of git).
5. **Appendices:**
   - A: `docs/commands.md`, complete, as the operations reference.
   - B: every manifest in the repo, grouped by where it is applied:
     Supervisor (`supervisor/**`, except `services/*.yml` packages, which are
     referenced by name only), workload cluster (`customer-cluster-01/**`),
     scripts (`scripts/**`).
   - C: section 4 of this guide (open items).
6. **Do not add** steps, versions or facts that are not in the repo. Where the
   repo says unverified, say so.
