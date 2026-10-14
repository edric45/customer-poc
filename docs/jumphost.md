# Jump host setup

Everything in the README runs from one Linux jump host (Ubuntu 22.04/24.04,
amd64 assumed) that reaches the Supervisor, the cluster VIPs, Harbor and
ArgoCD directly, and the internet through the proxy.

| Tool | Used for | Source | Internet needed |
|---|---|---|---|
| `kubectl` (+ `kubectl-vsphere`) | everything on the Supervisor and clusters | the Supervisor | no |
| `vcf` CLI | logins and kubeconfig contexts (`vcf context create`) | the Supervisor | no |
| `vcf` plugins (cluster, package, ...) | optional `vcf cluster ...` commands | public plugin registry, or the Supervisor's depot | yes, via proxy |
| `argocd` CLI | login, register clusters and the repo, sync, diff | the ArgoCD server itself | no |
| `docker` | push images to Harbor | Ubuntu packages | yes, via proxy |
| `git`, `jq`, `curl`, `unzip`, `openssl` | repo, scripts, Harbor secrets | Ubuntu packages | yes, via proxy |

Download paths checked on our VCF 9.1 lab (2026-10-14): the Supervisor
serves the VCF CLI 9.1.0.0 and the kubectl bundle, and ArgoCD serves its
own CLI.

## 1. Proxy for the shell

In `~/.bashrc`. `NO_PROXY` must cover everything internal, or `kubectl`,
`vcf` and `argocd` send Supervisor and cluster traffic to the proxy.

```sh
export HTTP_PROXY=http://proxy.customer.local:3128
export HTTPS_PROXY=http://proxy.customer.local:3128
# CHANGE: Supervisor IP, VPC / namespace networks (cluster API and LB VIPs), domain
export NO_PROXY=localhost,127.0.0.1,.customer.local,<SUPERVISOR_IP>,10.0.0.0/8,172.16.0.0/12
export http_proxy=$HTTP_PROXY https_proxy=$HTTPS_PROXY no_proxy=$NO_PROXY
```

`kubectl`, `vcf` and `argocd` are Go programs and accept CIDRs in `NO_PROXY`.
Older `curl` versions (before 7.86) only match names and exact IPs; the
commands below use `--noproxy '*'` for internal hosts to avoid the question.

apt through the proxy:

```sh
sudo tee /etc/apt/apt.conf.d/95proxy <<'EOF'
Acquire::http::Proxy "http://proxy.customer.local:3128";
Acquire::https::Proxy "http://proxy.customer.local:3128";
EOF
sudo apt-get update && sudo apt-get install -y git jq curl unzip openssl ca-certificates
```

## 2. kubectl, from the Supervisor

The Supervisor's download page (`https://<SUPERVISOR_IP>/`) offers the
kubectl bundle that matches it:

```sh
SV=<SUPERVISOR_IP>
mkdir -p ~/cli && cd ~/cli
curl -sk --noproxy '*' -O https://$SV/wcp/plugin/linux-amd64/vsphere-plugin.zip
unzip -o vsphere-plugin.zip
sudo install bin/kubectl bin/kubectl-vsphere /usr/local/bin/
kubectl version --client
```

## 3. VCF CLI, from the Supervisor

The path carries the CLI version and build, which the Supervisor publishes
in `buildInfo.json` (9.1.0.0, build 25296329 in our lab):

```sh
cd ~/cli
V=$(curl -sk --noproxy '*' https://$SV/resources/cliBuildInfo/buildInfo.json \
    | jq -r '"v" + (.version | ltrimstr("v")) + "/" + .buildNumber')
echo $V                                    # e.g. v9.1.0.0/25296329
curl -sk --noproxy '*' -O https://$SV/wcp/vcf-cli/$V/linux/amd64/vcf-cli.tar.gz
curl -sk --noproxy '*' -O https://$SV/wcp/vcf-cli/$V/linux/amd64/sha256sum.txt
sha256sum -c sha256sum.txt                 # vcf-cli.tar.gz: OK
tar xzf vcf-cli.tar.gz                     # one file: vcf-cli-linux_amd64
sudo install vcf-cli-linux_amd64 /usr/local/bin/vcf
vcf version
```

The download page may say "VCF Consumption CLI is currently unavailable"
(it did in our lab, "Fleet Depot Service" offline) while the files above
are still served. Use the direct paths.

### Plugins

`kubectl` work needs no plugins: the core `vcf` logs in and writes the
contexts. The plugins add `vcf cluster ...`, `vcf package ...` and similar.
On `vcf context create`, the CLI installs the plugins the Supervisor
recommends (cluster, kubernetes-release, namespaces, package, secret) from
its discovery source.

```sh
vcf plugin source list        # default: projects.packages.broadcom.com/... (via the proxy)
vcf plugin sync               # install what the current Supervisor recommends
vcf plugin list
```

If every `vcf` command is slow and `vcf context list` shows an `[x]` error
at the top, the source is unreachable. `vcf context create` can switch it to
the Supervisor's own depot, which may not hold the catalog. Reset it to the
public one (through the proxy):

```sh
vcf plugin source init
```

Never delete the last source (`vcf plugin source delete`): every `vcf`
command then crashes with `index out of range`.

## 4. Logins (contexts)

Logins expire after about 10 hours. `vcf context refresh <name>` renews the
Supervisor one. For a cluster, delete and create the context again (a
refresh of a cluster context can fail on certificate checks).

```sh
# Supervisor: kubectl context "<sv>"
vcf context create <sv> --endpoint $SV --insecure-skip-tls-verify \
  --auth-type basic --username <user>@<sso-domain>

# workload cluster (after README step 4): kubectl context "customer-cluster-01:customer-cluster-01"
vcf context create customer-cluster-01 --endpoint $SV --insecure-skip-tls-verify \
  --auth-type basic --username <user>@<sso-domain> \
  --workload-cluster-namespace customer-ns --workload-cluster-name customer-cluster-01

kubectl config get-contexts
```

`--auth-type basic` logs in with the vCenter SSO user directly. Without it,
a Supervisor that also trusts another identity provider (such as VCF
Automation) may pick OIDC and create no cluster context.

## 5. argocd CLI, from ArgoCD

After README step 3, ArgoCD serves the CLI matching its own version:

```sh
ARGO=<ARGOCD_IP>
cd ~/cli
curl -sk --noproxy '*' -o argocd https://$ARGO/download/argocd-linux-amd64
sudo install argocd /usr/local/bin/argocd
argocd version --client
```

Before ArgoCD exists, the same version from GitHub (through the proxy):
`https://github.com/argoproj/argo-cd/releases/download/v3.4.4/argocd-linux-amd64`.

## 6. Docker, for pushing images to Harbor

```sh
sudo apt-get install -y docker.io
sudo usermod -aG docker $USER            # log out and in again

# the Docker daemon does not read the shell's proxy variables
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf <<'EOF'
[Service]
Environment="HTTP_PROXY=http://proxy.customer.local:3128"
Environment="HTTPS_PROXY=http://proxy.customer.local:3128"
Environment="NO_PROXY=localhost,127.0.0.1,.customer.local,harbor.customer.local"
EOF
sudo systemctl daemon-reload && sudo systemctl restart docker
sudo systemctl show docker --property=Environment
```

Trust Harbor's CA (README step 2; all clients and checks in `docs/harbor-trust.md`) for Docker, and for the whole host
(curl, git, argocd):

```sh
curl -sk --noproxy '*' https://harbor.customer.local/api/v2.0/systeminfo/getcert -o harbor-ca.crt
sudo mkdir -p /etc/docker/certs.d/harbor.customer.local
sudo cp harbor-ca.crt /etc/docker/certs.d/harbor.customer.local/ca.crt
sudo cp harbor-ca.crt /usr/local/share/ca-certificates/harbor-customer.crt && sudo update-ca-certificates
```

Push a test image by hand (the project must exist in Harbor; `library`
exists by default). For a whole list, use `scripts/mirror-images.sh`
(README step 2):

```sh
docker login harbor.customer.local -u admin
docker pull nginxinc/nginx-unprivileged:1.27-alpine          # via the proxy
docker tag nginxinc/nginx-unprivileged:1.27-alpine harbor.customer.local/library/nginxinc/nginx-unprivileged:1.27-alpine
docker push harbor.customer.local/library/nginxinc/nginx-unprivileged:1.27-alpine
docker image rm nginxinc/nginx-unprivileged:1.27-alpine harbor.customer.local/library/nginxinc/nginx-unprivileged:1.27-alpine
```

## 7. Check the jump host

```sh
kubectl version --client; vcf version; argocd version --client; docker version --format '{{.Server.Version}}'
kubectl --context <sv> -n customer-ns get all              # Supervisor reachable, logged in
curl -sI https://github.com | head -1                   # internet via the proxy
curl -sk --noproxy '*' https://harbor.customer.local/api/v2.0/ping   # Pong
```
