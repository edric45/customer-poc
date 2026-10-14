# Command reference and troubleshooting

Day-to-day and troubleshooting commands for the POC, by area. Each block
says what it shows and what "good" looks like. Names, columns and resource
kinds were checked on our VCF 9.1 lab.

## Conventions

| Placeholder | Meaning |
|---|---|
| `<sv>` | Supervisor kubectl context (`vcf context create <sv> ...`) |
| `customer-cluster-01:customer-cluster-01` | workload cluster kubectl context |
| `customer-ns` | vSphere Namespace (ArgoCD, clusters, add-ons) |
| `<app>` / `<appset>` | ArgoCD Application / ApplicationSet name |

Short aliases used below (put them in `~/.bashrc`):

```sh
alias ksv='kubectl --context <sv> -n customer-ns'
alias kc='kubectl --context customer-cluster-01:customer-cluster-01'
```

## 1. Logins and contexts

```sh
kubectl config get-contexts
vcf context list
vcf context refresh <sv>                       # Supervisor login expired (~10 h)
# cluster login expired: recreate it (refresh can fail on certificate checks)
vcf context delete customer-cluster-01 -y
vcf context create customer-cluster-01 --endpoint $SV --insecure-skip-tls-verify \
  --auth-type basic --username <user>@<sso-domain> \
  --workload-cluster-namespace customer-ns --workload-cluster-name customer-cluster-01
```

Break-glass admin kubeconfig for the cluster, when SSO logins fail (it is
cluster-admin: keep it off shared disks, delete it after use):

```sh
ksv get secret customer-cluster-01-kubeconfig -o jsonpath='{.data.value}' | base64 -d > customer-cluster-01.kubeconfig
kubectl --kubeconfig customer-cluster-01.kubeconfig get nodes
```

`Unauthorized` / `You must be logged in to the server` = expired login.

## 2. Supervisor and namespace

```sh
ksv get all                                          # what runs in the namespace
ksv get virtualmachineclass,storageclass             # what clusters may use
ksv get resourcequota,storagepolicyquota             # limits and usage
ksv get events --sort-by=.lastTimestamp | tail -30   # recent problems first-last
kubectl --context <sv> get ns | grep '^svc-'         # installed Supervisor Services
kubectl --context <sv> get kubernetesreleases        # Kubernetes versions offered
kubectl --context <sv> -n vmware-system-vks-public get clusterclass
```

## 3. Workload cluster lifecycle

Status, top down:

```sh
ksv get cluster customer-cluster-01               # AVAILABLE True, PHASE Provisioned
ksv get kubeadmcontrolplane                    # control plane: READY = DESIRED
ksv get machinedeployments                     # worker pools: READY = DESIRED, PHASE Running
ksv get machines -o wide                       # every node: PHASE Running, NODENAME set
ksv get virtualmachines -o wide                # the VMs and their IPs
```

Why something is stuck:

```sh
ksv describe cluster customer-cluster-01 | sed -n '/Conditions/,$p'
ksv describe machine <machine>                 # e.g. "Waiting for a Node with spec.providerID"
ksv get events --field-selector involvedObject.name=<machine>
```

| Symptom | Meaning | Next |
|---|---|---|
| Machine Provisioning for long | VM not created or not booted | `ksv describe virtualmachine <vm>`: VM class, storage, quota |
| Machine Provisioned, "Waiting for a Node with spec.providerID" | VM is up, node never joined | SSH to the node (section 10): `journalctl -u kubelet`, `/var/log/cloud-init-output.log`; proxy / noProxy / taints |
| Cluster AVAILABLE False after a change | rollout in progress | `ksv get machines -w` |

Changes (replicas, VM class, versions) go through git: edit `cluster.yaml`,
push, then `argocd app diff customer-cluster-01` and `argocd app sync
customer-cluster-01`. Most changes replace nodes one at a time (rolling).

Inside the cluster:

```sh
kc get nodes -o wide                           # all Ready
kc top nodes                                   # metrics-server ships with VKS
kc get pods -A | grep -v -E 'Running|Completed'   # anything unhealthy
```

## 4. Add-ons

Declared on the Supervisor (AddonInstall + AddonConfig), installed by VKS
into the cluster as a PackageInstall (namespace `vmware-system-tkg`).

```sh
ksv get addoninstalls                                  # ours: cert-manager, istio
ksv get addonconfigs | grep customer-cluster-01           # READY True (includes VKS's own: antrea, ...)
ksv describe addoninstall customer-cluster-01-istio
ksv get addonconfig customer-cluster-01-istio -o jsonpath='{.status.conditions}' | jq

kc -n vmware-system-tkg get packageinstalls            # DESCRIPTION "Reconcile succeeded"
kc -n vmware-system-tkg describe packageinstall customer-cluster-01-istio | tail -20
```

What's available, and the settings an add-on accepts:

```sh
kubectl --context <sv> -n vmware-system-vks-public get addons
kubectl --context <sv> -n vmware-system-vks-public get addonreleases | grep <name>
kubectl --context <sv> -n vmware-system-vks-public get addonconfigdefinitions | grep <name>
kubectl --context <sv> -n vmware-system-vks-public get addonconfigdefinition <definition> -o yaml
```

Never `delete addonconfig --all`: VKS's own add-ons (the CNI among them) keep
AddonConfigs in the same namespace.

## 5. ArgoCD

### Status

```sh
argocd app list                                # SYNC STATUS + HEALTH for every app
argocd app list -l kind=vks-addon              # by label (set by our ApplicationSets)
argocd app get <app>                           # resources, conditions, last operation
argocd app get <app> --show-operation          # details of the running/last sync
argocd appset list
argocd appset get <appset>                     # generated apps + conditions
argocd cluster list                            # supervisor, customer-cluster-01: Successful
argocd repo list                               # Successful

# the same from kubectl (no argocd login needed)
ksv get applications                           # SYNC STATUS, HEALTH STATUS
ksv get applicationsets
ksv get application <app> -o jsonpath='{.status.conditions}' | jq
ksv get applicationset <appset> -o jsonpath='{.status.conditions}' | jq
```

| Status | Meaning |
|---|---|
| Synced / Healthy | git = live, resources healthy |
| OutOfSync | git differs from live: `argocd app diff <app>` |
| Progressing | applied, waiting for readiness (pods starting, VMs booting) |
| Degraded | a resource failed: `argocd app get <app>` lists which |
| Missing | resources not created yet (manual-sync apps before the first sync) |
| Unknown + ComparisonError | ArgoCD can't read git or reach the cluster: conditions say which |

### Sync

```sh
argocd app diff <app>                          # what a sync would change
argocd app sync <app>                          # sync now
argocd app sync <app> --prune                  # also delete resources removed from git
argocd app sync <app> --force                  # delete and re-create resources that can't be patched
argocd app sync <app> --resource apps:Deployment:<name>   # one resource only
argocd app sync -l kind=vks-addon              # every app with a label
argocd app wait <app> --sync --health --timeout 600
argocd app terminate-op <app>                  # stop a sync that hangs
```

Do not `--force` the Cluster app (`customer-cluster-01`): re-creating a Cluster
deletes its VMs.

### Refresh: make ArgoCD re-read git now

ArgoCD polls git about every 3 minutes. To not wait:

```sh
argocd app get <app> --refresh                 # re-compare with git
argocd app get <app> --hard-refresh            # also drop the manifest cache
# ApplicationSet: re-run its git generator (new or deleted folders)
ksv annotate applicationset <appset> argocd.argoproj.io/application-set-refresh=true --overwrite
```

Typical "I pushed a new add-on folder, nothing happened": refresh the
ApplicationSet, then `argocd app list -l kind=vks-addon`.

### History and logs

```sh
argocd app history <app>
argocd app manifests <app>                     # what ArgoCD renders from git
argocd app resources <app>
argocd app logs <app> --kind Deployment --name <name>   # pod logs through ArgoCD

# ArgoCD's own components (in customer-ns)
ksv logs deploy/argocd-repo-server --tail=100              # git clone / render errors
ksv logs statefulset/argocd-application-controller --tail=100   # sync / health errors
ksv logs deploy/argocd-applicationset-controller --tail=100     # generator errors
ksv logs deploy/argocd-server --tail=100                   # UI / API / login
ksv get argocd                                             # the instance: Ready / Failed
```

`argocd app rollback` is refused while automated sync is on; roll back with
`git revert` + push instead.

### Stuck deletes

An Application with the resources finalizer waits until everything it
deployed is gone. If that can never happen (cluster already deleted), drop
the finalizer. This leaves whatever still exists behind:

```sh
ksv patch application <app> --type merge -p '{"metadata":{"finalizers":null}}'
```

## 6. Kubernetes workloads

```sh
kc -n <ns> get pods -o wide
kc -n <ns> describe pod <pod> | tail -25       # Events: pull errors, scheduling, probes
kc -n <ns> logs <pod> -c <container> --tail=100
kc -n <ns> logs <pod> -c <container> --previous   # the crashed run
kc -n <ns> get events --sort-by=.lastTimestamp | tail -20
kc -n <ns> exec -it <pod> -c <container> -- sh
kc -n <ns> port-forward svc/<svc> 8080:80      # test a Service without the gateway
kc -n <ns> rollout restart deploy/<name>
kc -n <ns> rollout status deploy/<name>
kc top pods -n <ns>
```

| Error | Meaning | Fix |
|---|---|---|
| `violates PodSecurity "restricted:latest"` | VKS enforces "restricted" in unlabelled namespaces | add the securityContext it lists, or label the namespace `pod-security.kubernetes.io/enforce=baseline` |
| `ErrImagePull` + `x509` | registry CA not trusted on the nodes | `docs/harbor-trust.md` |
| `ErrImagePull` + `timeout` / `proxyconnect` | proxy / noProxy | `docs/proxy.md` |
| `ErrImagePull` + `unauthorized` | private Harbor project | pull secret (`docs/harbor-trust.md`, section 6) |
| `Pending`, `Insufficient cpu/memory` | workers full | more replicas or a bigger VM class (`cluster.yaml`) |
| `Pending`, PVC unbound | storage class / quota | `kc get pvc -n <ns>`, `ksv get storagepolicyquota` |
| `CrashLoopBackOff` | the app exits | `logs --previous` |

## 7. Istio and the gateway

```sh
kc get gatewayclass                                    # istio: ACCEPTED True
kc -n customer-gateway get gateway customer-gateway          # ADDRESS set, PROGRAMMED True
kc -n customer-gateway describe gateway customer-gateway | sed -n '/Status/,$p'   # per listener
kc get httproute -A
kc -n <ns> describe httproute <route> | sed -n '/Status/,$p'   # Accepted + ResolvedRefs True
kc -n customer-gateway get deploy,svc                     # customer-gateway-istio: Envoy + LoadBalancer
kc -n customer-gateway logs deploy/customer-gateway-istio --tail=50   # access log: one line per request
kc -n istio-system logs deploy/istiod --tail=50
kc -n customer-gateway get certificate                    # READY True
kc -n customer-gateway describe certificate customer-apps-tls
```

| Symptom | Look at |
|---|---|
| Gateway without ADDRESS | `kc -n customer-gateway get pods`; gateway pods rejected by Pod Security if `istio-gatewayclass-defaults` is missing |
| HTTPRoute `Accepted: False, NotAllowedByListeners` | namespace lacks the label `customer.local/gateway-access: "true"` |
| HTTPRoute `ResolvedRefs: False` | Service name/port wrong |
| 404 from Envoy | hostname not matching any route (use the name, not the IP) |
| TLS error | certificate not READY, or `*.apps.customer.local` doesn't match the name used |
| App pods 1/1 instead of 2/2 | no sidecar: namespace label `istio-injection=enabled`, then `rollout restart` |

Grafana and Headlamp:

```sh
kc -n grafana get pods,pvc,httproute
kc -n grafana logs deploy/grafana -c download-dashboards    # dashboards from grafana.com (via the proxy)
kc -n grafana logs deploy/grafana -c grafana --tail=50
kc -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d; echo
kc -n tanzu-system-monitoring get pods,svc                  # the Prometheus Grafana reads
kc -n headlamp get gateway,httproute,pods                   # Headlamp's own gateway
kc -n headlamp create token headlamp-admin --duration 8h    # Headlamp login
```

| Symptom | Look at |
|---|---|
| Grafana pod `CreateContainerConfigError` | Secret `grafana-admin` missing in namespace grafana |
| Grafana dashboards folder empty | `download-dashboards` log: proxy env in the Application's values, grafana.com reachable via the proxy |
| Grafana panels "No data" | data source URL `http://prometheus-server.tanzu-system-monitoring.svc.cluster.local`; Prometheus pods running |
| Headlamp "You don't have permissions" | logged in with the add-on's account: use a `headlamp-admin` token |
| Headlamp 404 / no route | opened by IP: the listener matches `headlamp.customer.local` only |

Test without DNS:

```sh
ADDR=$(kc -n customer-gateway get gateway customer-gateway -o jsonpath='{.status.addresses[0].value}')
curl -vk --noproxy '*' --resolve sample.apps.customer.local:443:$ADDR https://sample.apps.customer.local/
```

## 8. Harbor

```sh
curl -s --noproxy '*' https://harbor.customer.local/api/v2.0/ping          # Pong
curl -s --noproxy '*' https://harbor.customer.local/api/v2.0/health | jq   # every component "healthy"

NS=$(kubectl --context <sv> get ns -o name | grep -o 'svc-harbor-[a-z0-9]*')
kubectl --context <sv> -n $NS get pods,svc,pvc        # harbor-nginx has the EXTERNAL-IP
kubectl --context <sv> -n $NS logs deploy/harbor-core --tail=50
kubectl --context <sv> -n $NS logs deploy/harbor-registry --tail=50
kubectl --context <sv> -n $NS logs deploy/harbor-jobservice --tail=50   # proxy-cache, replication
```

Proxy-cache pulls failing: Harbor's own `proxy:` settings
(`harbor-values.yaml`), and the endpoint's health in Harbor UI >
Administration > Registries.

## 9. Proxy

```sh
env | grep -i _proxy                                   # jump host
curl -sI https://github.com | head -1                  # through the proxy
curl -s --noproxy '*' https://harbor.customer.local/api/v2.0/ping   # direct

kubectl --context <sv> -n customer-ns get argocd argocd -o jsonpath='{.spec.repo.proxy}' | jq   # ArgoCD
ksv get cluster customer-cluster-01 -o json | jq '.spec.topology.variables[] | select(.name=="osConfiguration") | .value.systemProxy'
```

On a node (section 10): `sudo systemctl show containerd --property=Environment`.
Test pulls through and around the proxy: `docs/proxy.md`, "Check at the customer".

## 10. On a node (SSH)

```sh
ksv get virtualmachines -o wide                        # node IPs
ksv get secret customer-cluster-01-ssh -o jsonpath='{.data.ssh-privatekey}' | base64 -d > key && chmod 600 key
ssh -i key vmware-system-user@<node-ip>

sudo journalctl -u kubelet --no-pager | tail -50       # registration, image pulls
sudo journalctl -u containerd --no-pager | tail -50
sudo tail -100 /var/log/cloud-init-output.log          # kubeadm join (new nodes)
sudo crictl ps -a                                      # containers on this node
sudo crictl pull harbor.customer.local/library/nginxinc/nginx-unprivileged:1.27-alpine   # from Harbor: direct
sudo crictl pull docker.io/library/busybox:1.37                       # from the internet: via the proxy
sudo systemctl show containerd --property=Environment  # proxy as containerd sees it
```

Delete the `key` file when done.

## 11. Cilium cluster

```sh
kubectl --context customer-cilium-01:customer-cilium-01 -n kube-system get pods -l k8s-app=cilium -o wide
kubectl --context customer-cilium-01:customer-cilium-01 -n kube-system exec ds/cilium -- cilium-dbg status --brief
ksv get addonconfig customer-cilium-01-cilium -o yaml     # the CNI's settings
```

More in `docs/cilium.md`.
