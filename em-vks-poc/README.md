# EM VKS POC: Argo CD and first cluster

Run after the setup document (content library, VPC, regional Harbor, Argo CD Service).

Replace `emr-cmdctr-xxxxx` with the real cmdctr namespace name in all files, and fill in
every `<...>` value.

Run everything from the namespace context: `vcf context use emr:<namespace>:default-project`.

| Step | File | How |
|---|---|---|
| 1 | `bootstrap/cmdctr/01-argocd-instance.yaml` | `kubectl apply -f`, wait for the instance to be Ready |
| 2 | `bootstrap/cmdctr/02-managedentity-cmdctr-namespace.yaml` | `kubectl apply -f`, wait for PHASE Ready |
| 3 | Register this git repository in Argo CD | UI: Settings → Repositories |
| 4 | `envs/cmdctr/clusters/emr-cmdctr-vks-01/cluster.yaml` | commit and push to git |
| 5 | `bootstrap/cmdctr/03-app-cmdctr-clusters.yaml` | `kubectl apply -f`; Argo CD creates the cluster |
| 6 | `bootstrap/cmdctr/04-managedentity-emr-cmdctr-vks-01.yaml` | `kubectl apply -f` once the cluster is Available |
| 7 | `envs/cmdctr/addons/emr-cmdctr-vks-01/` (cert-manager, contour, prometheus, fluent-bit) | commit and push; set the storage class (prometheus) and the log destination (fluent-bit) first |
| 8 | `bootstrap/cmdctr/05-appset-emr-cmdctr-vks-01-addons.yaml` | `kubectl apply -f`; one Argo CD Application per add-on folder |

Add-on versions are pinned in each file (`releaseFilter`). Check what the Supervisor offers
before committing: see `COMMANDS.md`.

Checks:

```sh
kubectl get argocd                        # instance status
kubectl get managedentity                 # PHASE Ready
kubectl get cluster emr-cmdctr-vks-01     # Available True
```

The Cluster carries `argocd.argoproj.io/sync-options: Prune=false,Delete=false`: Argo CD
never deletes it. Deleting a cluster is done by hand with kubectl.
