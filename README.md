# Customer VKS POC

VCF 9.1 Supervisor with NSX VPC networking, behind an outbound proxy:

0. Jump host: kubectl, vcf CLI, argocd CLI, docker
1. Supervisor (vCenter)
2. Regional Harbor (Supervisor Service)
3. ArgoCD (Supervisor Service), with the Supervisor and the git repo added
4. VKS workload cluster `customer-cluster-01` (uses the proxy, trusts Harbor automatically), added to ArgoCD
5. Add-ons (cert-manager, Istio, Headlamp) as an ArgoCD ApplicationSet
6. Shared Istio gateway (Gateway API), Grafana (open-source chart) and a sample app, as ArgoCD Applications + ApplicationSet
7. Optional: the same cluster with Cilium instead of Antrea

Checked against our VCF 9.1 lab: every manifest passes a server dry-run, and
field names come from the Supervisor's own schemas. The lab has no proxy and
uses Avi instead of the NSX load balancer. Neither changes these files, but
the proxy paths are first exercised at the customer.

## Documents, in reading order

| Document | What it is for |
|---|---|
| `GUIDE.md` | **start here**: installation order, where each step is done, which files and docs belong to it, how to tell it worked; renaming for a real customer; how to build one complete document |
| `README.md` (this file) | the runbook: steps 0 to 7, in order |
| `docs/jumphost.md` | step 0: installing kubectl, the vcf CLI and plugins, the argocd CLI and Docker behind the proxy |
| `supervisor/services/README.md` | step 2 and 3: the Supervisor Service packages, adding and installing them in vCenter |
| `docs/harbor-trust.md` | getting Harbor's CA and trusting it: jump host, Docker, clusters, ArgoCD, laptops |
| `docs/git-repos.md` | step 3.4: adding the customer's private GitHub / GitLab repo to ArgoCD (token, SSH, private CA, proxy) |
| `docs/proxy.md` | every place the proxy is set, and what noProxy must contain |
| `docs/commands.md` | day-to-day and troubleshooting commands: cluster, add-ons, ArgoCD (status, sync, refresh), workloads, gateway, Harbor, nodes |
| `docs/cilium.md` | step 7: the Cilium cluster and how it differs from Antrea |

Conventions used in all of them: `<sv>` is the Supervisor kubectl context,
`customer-cluster-01:customer-cluster-01` the cluster's, `customer-ns` the vSphere
Namespace; names under `.customer.local` and `proxy.customer.local:3128` are
placeholders (table below). Statements carry their source: **lab** (seen on
our VCF 9.1 lab), **documented** (Broadcom or upstream docs), or
**unverified** (to confirm at the customer).

## Layout

The top folder names the API server a file is applied to.

```
GUIDE.md                            master guide: order, file map, renaming, building the document
supervisor/                         applied to the SUPERVISOR
  services/                         Supervisor Service packages from Broadcom (uploaded in vCenter)
    README.md                       which file is for what, how to add and install them
    harbor/                         Harbor 2.15.2 package + harbor-values.yaml (our configuration)
    argocd/                         ArgoCD Service 1.2.0 package
    contour/, velero/               optional, not used by the POC
  argocd/argocd.yaml                the ArgoCD instance in customer-ns
  clusters/customer-cluster-01/
    cluster.yaml                    the workload cluster (Antrea)
    addons/<name>/                  one VKS add-on per folder (AddonConfig + AddonInstall)
  clusters/customer-cilium-01/
    cluster.yaml                    the same cluster with Cilium
  applications/
    customer-cluster-01.yaml           ArgoCD Application for the Cluster (MANUAL sync)
    customer-cluster-01-platform.yaml  ArgoCD Application for the gateway inside the cluster
    customer-cluster-01-grafana.yaml   ArgoCD Application for Grafana (Helm chart + monitoring/)
  applicationsets/
    customer-cluster-01-addons.yaml    one Application per folder in addons/
    customer-cluster-01-apps.yaml      one Application per folder in customer-cluster-01/apps/
customer-cluster-01/                   applied INSIDE the workload cluster (by ArgoCD)
  platform/                         shared Istio Gateway, wildcard cert, gateway pod fix, Headlamp login
  monitoring/                       Grafana's namespace and HTTPRoute (the chart is in its Application)
  apps/sample-app/                  sample app: namespace, Deployment, Service, HTTPRoute
scripts/                            run on the jump host
  images.txt                        public images to copy into Harbor
  mirror-images.sh                  pull, retag, push to Harbor, clean up (settings via env variables)
docs/
  jumphost.md                       installing the CLIs and Docker behind the proxy
  harbor-trust.md                   getting Harbor's CA, trusting it everywhere it's needed
  git-repos.md                      adding a private GitHub / GitLab repo to ArgoCD
  proxy.md                          where the proxy is set, layer by layer; noProxy
  commands.md                       command reference and troubleshooting
  cilium.md                         cluster with Cilium; what changes vs Antrea
```

## Values to set for the customer

Replace before the first push; the files carry these placeholders.

| Placeholder | Meaning | Files |
|---|---|---|
| `customer-ns` | the vSphere Namespace | all of `supervisor/` |
| `http://proxy.customer.local:3128` | the proxy | harbor-values, argocd, cluster.yaml, docs |
| `.customer.local`, `harbor.customer.local`, `*.apps.customer.local`, `headlamp.customer.local` | internal domain, Harbor name, app wildcard (sample app, Grafana), Headlamp | harbor-values, cluster.yaml, platform/, monitoring/, apps/, headlamp add-on, grafana app |
| `10.0.0.0/8`, `172.16.0.0/12` in noProxy | VPC / namespace networks + Supervisor management network | argocd, cluster.yaml |
| `https://git.customer.local/platform/customer-poc.git` | where this repo is hosted (marked `# CHANGE`) | applications/, applicationsets/ |
| `vsan-default-storage-policy` | storage policy on the namespace / Supervisor | harbor-values, cluster.yaml |
| `best-effort-medium`, `best-effort-large` | VM classes on the namespace | cluster.yaml |
| `v1.35.6+vmware.2`, `builtin-generic-v3.7.0` | Kubernetes release and ClusterClass on the customer's Supervisor | cluster.yaml |

Names used in the commands: `$SV` is the Supervisor IP, `<sv>` the Supervisor
kubectl context, `customer-cluster-01:customer-cluster-01` the cluster's context,
`$ARGO` the ArgoCD IP.

## Step 0: Jump host

Full commands in `docs/jumphost.md`. In short:

| Tool | From |
|---|---|
| `kubectl` | `https://$SV/wcp/plugin/linux-amd64/vsphere-plugin.zip` |
| `vcf` CLI | `https://$SV/wcp/vcf-cli/<version>/<build>/linux/amd64/vcf-cli.tar.gz` |
| `vcf` plugins | installed by `vcf context create` / `vcf plugin sync` (through the proxy) |
| `argocd` CLI | `https://$ARGO/download/argocd-linux-amd64` (after step 3) |
| `docker` | `apt-get install docker.io`, with the daemon proxy as a systemd drop-in |

Shell proxy variables with a complete `NO_PROXY` come first (jumphost.md,
section 1); without them the CLIs send Supervisor traffic to the proxy.

## Step 1: Supervisor (vCenter)

Done in vCenter as for any VCF 9.1 Supervisor on NSX VPC. For this POC:

- **Proxy, two places** (`docs/proxy.md`):
  - vCenter appliance (VAMI :5480) > Networking > Proxy: content library
    and downloads.
  - Supervisor > Configure > Network > Proxy: inherit vCenter's, or set it.
- **Content library** "vSphere Kubernetes Service" synced. It downloads node
  images through vCenter's proxy. If a download fails with "cannot
  authenticate SSL certificate", accept the publisher's renewed certificate
  in the library's settings.
- **vSphere Namespace `customer-ns`**: storage policy, VM classes
  (best-effort-medium, best-effort-large), edit permission for the POC users.

Log in and check what the cluster file needs:

```sh
vcf context create <sv> --endpoint $SV --insecure-skip-tls-verify \
  --auth-type basic --username <user>@<sso-domain>
kubectl --context <sv> -n customer-ns get virtualmachineclass,storageclass
kubectl --context <sv> get kubernetesreleases | grep -E 'NAME|v1.35'
kubectl --context <sv> -n vmware-system-vks-public get clusterclass
```

The release and ClusterClass in `cluster.yaml` must appear; change the file
if the customer's differ.

## Step 2: Regional Harbor

Harbor first, before any cluster: VKS clusters on this Supervisor then trust
Harbor's certificate from the start. Installing Harbor after clusters exist
rolls their nodes to add it (Broadcom docs).

1. Register the service in vCenter (details in `supervisor/services/README.md`):
   Supervisor Management > Services. vCenter 9.1 already lists Harbor 2.14.2.
   To use 2.15.2, add it as a new version with
   `supervisor/services/harbor/supervisor-service-harbor-v2.15.2+vmware.1-vks.1-25639075.yml`.
   If 2.15.2 fails validation ("Image ... does not exist"), the depot lacks
   it: use 2.14.2, the values work for both.
2. Create a local copy with generated secrets (ignored by git). Then set the
   admin password (`SET_ADMIN_PASSWORD`) and the customer values in it:

   ```sh
   cd supervisor/services/harbor
   awk '{ while (match($0,/REPLACE_ME(_16_CHARS|_32_CHARS)?/)) { t=substr($0,RSTART,RLENGTH);
     n=(t~/16/)?8:(t~/32/)?16:12; cmd="openssl rand -hex " n; cmd | getline r; close(cmd);
     $0=substr($0,1,RSTART-1) r substr($0,RSTART+RLENGTH) } print }' \
     harbor-values.yaml > harbor-values.local.yaml
   ```

   Harbor > Actions > Install on Supervisors: paste `harbor-values.local.yaml`
   into the configuration box. Keep the file, don't commit it.

   Keep `tlsCertificate.tlsSecretLabels` exactly as it is: that label is what
   makes VKS clusters trust Harbor automatically.
3. Harbor gets a LoadBalancer VIP (Service `harbor-nginx`). Create the DNS
   record `harbor.customer.local` for it:

   ```sh
   kubectl --context <sv> get svc -A | grep harbor-nginx       # EXTERNAL-IP
   curl -sk --noproxy '*' https://harbor.customer.local/api/v2.0/ping   # Pong
   ```

4. Get Harbor's CA and trust it on the jump host (Docker, curl, git). The
   clusters trust it on their own. Other ways to get it, checks, and every
   other client (ArgoCD, laptops, pods) are in `docs/harbor-trust.md`:

   ```sh
   curl -sk --noproxy '*' https://harbor.customer.local/api/v2.0/systeminfo/getcert -o harbor-ca.crt
   openssl x509 -in harbor-ca.crt -noout -subject     # subject=CN=Harbor CA (not CN=harbor)
   sudo cp harbor-ca.crt /usr/local/share/ca-certificates/harbor-customer.crt && sudo update-ca-certificates
   sudo mkdir -p /etc/docker/certs.d/harbor.customer.local
   sudo cp harbor-ca.crt /etc/docker/certs.d/harbor.customer.local/ca.crt
   ```

5. Copy the POC's public images into Harbor's `library` project with
   `scripts/mirror-images.sh` (from the jump host, with Docker set up as in
   `docs/jumphost.md` section 6). It reads `scripts/images.txt`, then pulls,
   retags, pushes and removes the local copies. The pull tests in
   `docs/harbor-trust.md` and `docs/proxy.md` use one of these images:

   ```sh
   export HARBOR=harbor.customer.local HARBOR_PROJECT=library HARBOR_USER=admin
   DRY_RUN=1 ./scripts/mirror-images.sh      # see the source -> target names first
   ./scripts/mirror-images.sh                # asks for the password
   # e.g. nginxinc/nginx-unprivileged:1.27-alpine -> harbor.customer.local/library/nginxinc/nginx-unprivileged:1.27-alpine
   ```

   Settings (`CREATE_PROJECT`, `PLATFORM`, `CLEANUP`, ...) are listed at the
   top of the script. Add images to `images.txt` and run it again; pushing
   an image that is already there is harmless.

   Public images (the sample app, Grafana) come straight from Docker Hub
   through the node proxy, not through Harbor. Optional later: a Harbor
   proxy-cache project for Docker Hub (Administration > Registries > New
   Endpoint, then a project with Proxy Cache on). It keeps copies inside and
   spares Docker Hub's anonymous pull limit, which all nodes share when they
   leave through one proxy address.

6. Commit and push this repo: ArgoCD reads it from step 3 on.

## Step 3: ArgoCD

### 3.1 Install

The ArgoCD Service must be installed on the Supervisor (vCenter >
Supervisor Management > Services, no configuration needed). If it isn't
listed, add `supervisor/services/argocd/supervisor-service-argocd-1.2.0-25642124.yml`;
our lab runs that exact package. The `ArgoCD` resource is then the whole
install:

```sh
kubectl --context <sv> get argocdversions argocd-supported-versions -o yaml   # version still offered?
kubectl --context <sv> apply -f supervisor/argocd/argocd.yaml
kubectl --context <sv> -n customer-ns get argocd,pods -w        # until Ready
```

### 3.2 Log in

```sh
kubectl --context <sv> -n customer-ns get svc argocd-server     # EXTERNAL-IP -> ARGO
ARGO=<EXTERNAL-IP>
kubectl --context <sv> -n customer-ns get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
# CLI from the server itself (jumphost.md, section 5), then:
argocd login $ARGO --username admin --insecure
```

UI: `https://$ARGO`, same user and password.

### 3.3 Add the Supervisor to ArgoCD

ArgoCD runs on the Supervisor but does not manage it until it is added as a
cluster. Add it as `supervisor`, limited to customer-ns: ArgoCD gets a
ServiceAccount and a RoleBinding in customer-ns only, nothing cluster-wide.

```sh
argocd cluster add <sv> --name supervisor \
  --namespace customer-ns --system-namespace customer-ns \
  --service-account argocd-manager -y
argocd cluster list        # supervisor  https://<SV>:443  (1 namespaces)
```

| Flag | Why |
|---|---|
| `<sv>` | the kubectl context the CLI reads the address and login from |
| `--namespace customer-ns` | ArgoCD may only manage this namespace |
| `--system-namespace customer-ns` | its ServiceAccount lives here too (not kube-system, which you can't write to) |

The Applications reach it as `destination: name: supervisor`.

### 3.4 Add the git repo

Full options (GitHub or GitLab, token or SSH, credential templates, private
CA, proxy, errors) in `docs/git-repos.md`. The usual case, a private repo
with a read-only token:

```sh
# private CA on the git server only:
argocd cert add-tls git.customer.local --from git-ca.crt
# the token stays in ArgoCD, never in this repo
argocd repo add https://git.customer.local/platform/customer-poc.git --username <user> --password <token>
argocd repo list          # CONNECTION STATUS Successful
```

ArgoCD clones through the proxy in `argocd.yaml`, unless the git server is in
its noProxy (`.customer.local` is). The `repoURL` in every Application and
ApplicationSet must be exactly this URL (`docs/git-repos.md`, section 6).

## Step 4: Bring up the workload cluster

### 4.1 Create it

Check first: Harbor is installed (step 2), so the cluster trusts it from the start, and
the customer values in `cluster.yaml` are pushed.

Through ArgoCD (recommended: the Cluster lives in git, and every later
change is a reviewed sync):

```sh
kubectl --context <sv> apply -f supervisor/applications/customer-cluster-01.yaml
argocd app get customer-cluster-01       # OutOfSync: the Cluster does not exist yet
argocd app diff customer-cluster-01      # review: one Cluster
argocd app sync customer-cluster-01      # creates the VMs (manual sync on purpose)
```

Or directly, without ArgoCD (same file):

```sh
kubectl --context <sv> apply -f supervisor/clusters/customer-cluster-01/cluster.yaml
```

### 4.2 Watch it come up

About 10 to 15 minutes: control plane first, then the workers.

```sh
kubectl --context <sv> -n customer-ns get cluster customer-cluster-01
kubectl --context <sv> -n customer-ns get machines -w     # all Running
kubectl --context <sv> -n customer-ns get virtualmachines -o wide
```

Ready when the Cluster's `AVAILABLE` is True and every Machine is Running
with a node name. If a Machine stays at "Waiting for a Node with
spec.providerID", see Troubleshooting.

### 4.3 Log in to the cluster

```sh
vcf context create customer-cluster-01 --endpoint $SV --insecure-skip-tls-verify \
  --auth-type basic --username <user>@<sso-domain> \
  --workload-cluster-namespace customer-ns --workload-cluster-name customer-cluster-01
kubectl --context customer-cluster-01:customer-cluster-01 get nodes -o wide
```

### 4.4 Add the workload cluster to ArgoCD

```sh
argocd cluster add customer-cluster-01:customer-cluster-01 --name customer-cluster-01 -y
argocd cluster list       # customer-cluster-01  https://<cluster API VIP>:6443
```

This creates a ServiceAccount `argocd-manager` in the cluster's kube-system
with cluster-admin, and stores its token in ArgoCD. Applications reach the
cluster as `destination: name: customer-cluster-01`.

## Step 5: Add-ons (ApplicationSet)

```sh
kubectl --context <sv> apply -f supervisor/applicationsets/customer-cluster-01-addons.yaml
argocd app list -l kind=vks-addon     # customer-cluster-01-cert-manager, -istio, -headlamp
kubectl --context <sv> -n customer-ns get addoninstalls | grep customer-cluster-01
kubectl --context customer-cluster-01:customer-cluster-01 get pods -n cert-manager
kubectl --context customer-cluster-01:customer-cluster-01 get pods -n istio-system
kubectl --context customer-cluster-01:customer-cluster-01 -n headlamp get gateway,pods
```

| Add-on | Exposed | Notes |
|---|---|---|
| cert-manager | no | issues the gateway certificates (ClusterIssuer `selfsigned`, a private CA) |
| istio | no | sidecar mode; ingress through Gateway API, class `istio` |
| headlamp | its **own** Istio Gateway, `https://headlamp.customer.local` | the add-on can't use the shared gateway; DNS record `headlamp.customer.local` -> `kubectl -n headlamp get gateway` ADDRESS. Login token: step 6 |

VKS also installs some add-ons by itself, without an AddonInstall from us
(our lab: Antrea, Prometheus, telegraf, metrics-server). Prometheus is what
Grafana reads in step 6:

```sh
kubectl --context <sv> -n customer-ns get addonconfigs | grep customer-cluster-01
kubectl --context customer-cluster-01:customer-cluster-01 -n tanzu-system-monitoring get pods,svc
```

These Applications deploy to the **Supervisor** (AddonConfig and
AddonInstall in customer-ns); VKS then installs the add-on into the cluster.
Another add-on is another folder under
`supervisor/clusters/customer-cluster-01/addons/` and a push. What's on offer:

```sh
kubectl --context <sv> -n vmware-system-vks-public get addons
kubectl --context <sv> -n vmware-system-vks-public get addonreleases | grep <name>
```

## Step 6: Istio gateway, Grafana and sample app

Everything reachable over HTTPS goes through Gateway API with GatewayClass
`istio`: one shared Gateway for `*.apps.customer.local` (sample app, Grafana),
plus Headlamp's own Gateway from step 5.

| URL | Gateway | Deployed by |
|---|---|---|
| `https://sample.apps.customer.local` | shared `customer-gateway` | ApplicationSet `customer-cluster-01-apps` |
| `https://grafana.apps.customer.local` | shared `customer-gateway` | Application `customer-cluster-01-grafana` |
| `https://headlamp.customer.local` | Headlamp's own | headlamp add-on (step 5) |

### 6.1 The shared gateway and the sample app

```sh
# the shared gateway (one Application)
kubectl --context <sv> apply -f supervisor/applications/customer-cluster-01-platform.yaml
# the apps (one ApplicationSet: one Application per folder in customer-cluster-01/apps/)
kubectl --context <sv> apply -f supervisor/applicationsets/customer-cluster-01-apps.yaml
argocd app list               # customer-cluster-01-platform, app-sample-app: Synced, Healthy

k() { kubectl --context customer-cluster-01:customer-cluster-01 "$@"; }
k -n customer-gateway get gateway customer-gateway        # ADDRESS, PROGRAMMED True
k -n sample-app get pods                            # 2/2 = app + Istio sidecar
```

DNS: `*.apps.customer.local` -> the gateway ADDRESS. Before DNS exists:

```sh
curl -k --noproxy '*' --resolve sample.apps.customer.local:443:<ADDRESS> https://sample.apps.customer.local/
curl -sI --noproxy '*' --resolve sample.apps.customer.local:80:<ADDRESS> http://sample.apps.customer.local/   # 301 to https
```

To drop `-k`, trust the gateway's root CA (cert-manager's `selfsigned` issuer):

```sh
k -n cert-manager get secret selfsigned-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > customer-apps-ca.crt
```

Onboarding another app: copy `customer-cluster-01/apps/sample-app/` to a new
folder, change the names, image and hostname, then push. The ApplicationSet
creates `app-<folder>`. The namespace label `customer.local/gateway-access: "true"`
is what lets its HTTPRoute use the shared gateway.

### 6.2 Headlamp login

The platform app also creates the `headlamp-admin` account (the add-on's own
account has no rights). A token to paste at the login page:

```sh
k -n headlamp create token headlamp-admin --duration 8h
```

### 6.3 Grafana

There is no VKS add-on for Grafana: it comes from the open-source Helm chart
(`grafana-community/helm-charts`, version 13.5.1, Grafana 13.2), through an
ArgoCD Application with two sources: the chart with its values, and
`customer-cluster-01/monitoring/` (namespace + HTTPRoute). It reads the Prometheus
that VKS installs. Images come from Docker Hub through the node proxy.

```sh
# 1. admin login, kept out of git (before the first sync)
k create namespace grafana
k label namespace grafana customer.local/gateway-access=true
k -n grafana create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password="$(openssl rand -base64 18)"
k -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo

# 2. the Application
kubectl --context <sv> apply -f supervisor/applications/customer-cluster-01-grafana.yaml
argocd app get customer-cluster-01-grafana          # Synced, Healthy
k -n grafana get pods,pvc,httproute
```

Open `https://grafana.apps.customer.local` (same wildcard DNS and CA as the
sample app). Folder "Kubernetes" holds five dashboards from grafana.com
(Node Exporter Full, Kubernetes Views: Global, Namespaces, Nodes, Pods). An
init container downloads them at startup **through the proxy**, set
explicitly in the values (pods don't inherit the node proxy). If they're
missing, check its log:

```sh
k -n grafana logs deploy/grafana -c download-dashboards
```

Checked in our lab: the chart rendered with these values passes a server
dry-run, and its pod passes VKS's "restricted" Pod Security (the chart's
chown init container is turned off for that reason).

## Step 7 (optional): Cilium

`docs/cilium.md`.

## ArgoCD reference: adding Applications and ApplicationSets

Applications and ApplicationSets are Kubernetes resources in ArgoCD's
namespace (customer-ns, on the Supervisor). The source is git; the destination
is a cluster added in steps 3.3 / 4.4.

| | Application | ApplicationSet |
|---|---|---|
| What | one folder of git -> one destination | a template that generates Applications |
| Used here for | the Cluster (manual sync), the shared gateway | add-ons (one per folder), apps (one per folder) |
| Add another | a new YAML file | a new folder, then push. Nothing to apply |

Two ways to add one; the YAML is the same:

```sh
# 1. kubectl on the Supervisor (what this README uses)
kubectl --context <sv> apply -f supervisor/applications/<file>.yaml
kubectl --context <sv> apply -f supervisor/applicationsets/<file>.yaml

# 2. argocd CLI
argocd app create -f supervisor/applications/<file>.yaml --upsert
argocd appset create supervisor/applicationsets/<file>.yaml --upsert
```

A new app without writing YAML first (handy for a demo; it is not in git
until you write it down):

```sh
argocd app create demo --repo https://git.customer.local/platform/customer-poc.git \
  --path customer-cluster-01/apps/sample-app --dest-name customer-cluster-01 \
  --sync-policy automated
```

Day-to-day:

```sh
argocd app list
argocd app get <app>                 # status, resources, last sync
argocd app diff <app>                # git vs live
argocd app sync <app>
argocd appset list
argocd app delete <app> -y           # with the resources finalizer: also deletes what it deployed
```

## Troubleshooting

Command reference by area, with status meanings and error tables:
`docs/commands.md`. The most common problems:

| Symptom | Look at |
|---|---|
| Machine stuck "Waiting for a Node with spec.providerID" | the node never registered: SSH to the VM, `journalctl -u kubelet`, `/var/log/cloud-init-output.log` (proxy, noProxy, duplicate taints) |
| `ErrImagePull` from Harbor, x509 | automatic trust missing: `tlsSecretLabels` changed in harbor-values, or the cluster predates Harbor and hasn't rolled yet. `docs/harbor-trust.md`, section 4 |
| Pushed a new folder, no new ArgoCD app | ApplicationSets poll git every 3 min: `kubectl --context <sv> -n customer-ns annotate applicationset <appset> argocd.argoproj.io/application-set-refresh=true --overwrite` |
| `violates PodSecurity "restricted:latest"` | VKS enforces "restricted" in unlabelled namespaces: fix the pod's securityContext, or label the namespace `baseline` |
| `ErrImagePull` from Harbor, timeout or 403 from the proxy | Harbor missing from `noProxy` |
| Gateway without ADDRESS | `istio-gatewayclass-defaults` missing (gateway pods rejected by Pod Security) |
| ArgoCD repo "connection refused / timeout" | `spec.repo.proxy`, or the git server belongs in noProxy |
| `argocd cluster add`: timeout | the jump host's `NO_PROXY` misses the Supervisor or cluster VIP |
| ArgoCD instance `Failed` after a Supervisor update | `spec.version` dropped off the supported list |
| kubectl `Unauthorized` | login expired (~10 h): `vcf context refresh <sv>`; for the cluster, delete and create the context |

SSH to a node:

```sh
kubectl --context <sv> -n customer-ns get virtualmachines -o wide
kubectl --context <sv> -n customer-ns get secret customer-cluster-01-ssh \
  -o jsonpath='{.data.ssh-privatekey}' | base64 -d > key && chmod 600 key
ssh -i key vmware-system-user@<node-ip>
```

## Cleanup

```sh
argocd app delete app-sample-app customer-cluster-01-grafana customer-cluster-01-platform -y
kubectl --context <sv> delete -f supervisor/applicationsets/     # add-ons uninstalled by the finalizers
argocd cluster rm customer-cluster-01
# the Cluster is protected from ArgoCD deletes; remove it by hand:
kubectl --context <sv> -n customer-ns delete cluster customer-cluster-01
```

Deleting a Cluster deletes its VMs and leaves its volumes behind as PVCs in
customer-ns. Never `delete addonconfig --all` in the namespace: the CNI and other
platform add-ons keep AddonConfigs there too.
