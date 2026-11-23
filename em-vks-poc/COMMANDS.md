# Useful commands

Run from the namespace context unless the line says "admin".
`<ns>` = the vSphere Namespace (e.g. emr-cmdctr-xxxxx).

## Login and contexts

```sh
vcf context list                      # all contexts
vcf context use <context>             # switch, e.g. emr:<ns>:default-project
vcf context refresh <context>         # login expired ("Unauthorized")
kubectl config current-context        # which one am I on?
```

## What the Supervisor offers

```sh
kubectl get kr                                            # Kubernetes releases (READY / COMPATIBLE)
kubectl -n vmware-system-vks-public get clusterclass      # ClusterClass versions (use the newest)
kubectl -n <ns> get virtualmachineclass                   # VM sizes bound to the namespace
kubectl -n <ns> get storageclass                          # storage classes bound to the namespace
```

## Argo CD Service and instance

```sh
kubectl get argocdversions argocd-supported-versions -o yaml   # Argo CD versions (use Recommended)
kubectl -n <ns> get argocd                                      # instance status
kubectl -n <ns> get pods | grep argocd                          # instance pods
kubectl -n <ns> get svc argocd-server-vip                       # UI / API address (EXTERNAL-IP)
kubectl -n <ns> get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo             # admin password
kubectl -n <ns> get managedentity                               # registered destinations (PHASE Ready)
```

## Argo CD CLI

```sh
argocd login <EXTERNAL-IP> --username admin --insecure    # log in (asks for the password)
argocd version                                            # client and server versions
argocd cluster list                                       # destinations (from ManagedEntities)
argocd repo add <git URL> --username <user> --password <token>
argocd repo list
argocd app list                                           # all apps and their sync / health
argocd app get <app>                                      # one app in detail
argocd app diff <app>                                     # what would change
argocd app sync <app>                                     # sync now
argocd app terminate-op <app>                             # stop a stuck sync
```

## Clusters

```sh
kubectl -n <ns> get cluster                       # clusters and their phase
kubectl -n <ns> get machines                      # nodes being created / running
kubectl -n <ns> describe cluster <cluster>        # why a cluster is not ready
kubectl -n <ns> get secret <cluster>-kubeconfig \
  -o jsonpath='{.data.value}' | base64 -d > <cluster>.kubeconfig
kubectl --kubeconfig <cluster>.kubeconfig get nodes   # inside the cluster
```

## Add-ons

```sh
kubectl -n vmware-system-vks-public get addonreleases                        # all add-on versions
kubectl -n vmware-system-vks-public get addonreleases | grep cert-manager    # one add-on
kubectl -n vmware-system-vks-public get addonreleases | grep contour
kubectl -n vmware-system-vks-public get addonreleases | grep prometheus
kubectl -n vmware-system-vks-public get addonreleases | grep fluent-bit
kubectl -n vmware-system-vks-public get addonconfigdefinition \
  <addon>.kubernetes.vmware.com.<version with --- before vmware> -o yaml     # settings an add-on accepts
kubectl -n <ns> get addoninstall,addonconfig                                 # what is installed, and status
kubectl --kubeconfig <cluster>.kubeconfig get pods -A                        # add-on pods inside the cluster
```

Never `kubectl delete addonconfig --all`: platform add-ons (e.g. the Antrea CNI) keep
their configs in the same namespace.

## Harbor and depot (admin)

```sh
kubectl get svc -A | grep harbor-nginx                # Harbor IP (EXTERNAL-IP)
kubectl -n kube-system get endpoints depot            # depot points at Harbor
kubectl get pods -A | grep -i harbor                  # Harbor pods
```

## Supervisor services (admin)

```sh
kubectl get pods -A | grep -i argocd-service           # Argo CD operator running?
kubectl get pods -A -o jsonpath='{..image}' | tr ' ' '\n' | grep -i argocd-service | sort -u
                                                       # depot.kube-system.svc/... = Software Depot manifest
kubectl get clustercontentlibraries                    # content libraries and sync state
```
