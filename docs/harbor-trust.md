# Trusting the regional Harbor's certificate

Harbor (Supervisor Service) signs its own certificate with its own CA,
"Harbor CA", unless the customer supplied one. Anything that talks to Harbor over
TLS must trust that CA, or it fails with
`x509: certificate signed by unknown authority`.

Placeholders: `harbor.customer.local` is Harbor's hostname; `<sv>` the
Supervisor kubectl context.

## 1. Who needs it

| Client | Trusts Harbor automatically? | What to do |
|---|---|---|
| VKS cluster nodes (containerd image pulls) | **yes**, when Harbor is a Supervisor Service on the same Supervisor with `tlsSecretLabels: {"managed-by": "vmware-vRegistry"}` (Broadcom docs) | nothing; check with section 4. Fallback in section 4 |
| Jump host: curl, git, helm, argocd CLI | no | section 3 |
| Docker / Podman on the jump host | no | section 3 |
| ArgoCD, if it pulls Helm charts or OCI artifacts from Harbor | no | section 5 |
| Pods that call Harbor's API (CI jobs, scanners) | no | mount the CA (section 6) |
| Browsers and laptops | no | section 7 |
| vSphere Pods on the Supervisor | unverified on 9.1 (Broadcom's 8.0 docs say not automatic) | test before relying on it |

## 2. Get the CA certificate

Three ways, same result. In our lab all of them returned the same CA
(`CN=Harbor CA`).

**A. Harbor's API** (no login needed):

```sh
curl -sk --noproxy '*' https://harbor.customer.local/api/v2.0/systeminfo/getcert -o harbor-ca.crt
```

**B. From the Supervisor**: the CA is in the `harbor-tls` secret in Harbor's
service namespace. Read only the `ca.crt` key (the secret also holds the
private key; leave that alone):

```sh
NS=$(kubectl --context <sv> get ns -o name | grep -o 'svc-harbor-[a-z0-9]*')
kubectl --context <sv> -n $NS get secret harbor-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > harbor-ca.crt
```

**C. Harbor UI**: Projects > any project > **Registry Certificate** (download
link at the top of the project page).

**Not `openssl s_client`.** Harbor only sends its own server certificate
(`CN=harbor`, issued by Harbor CA) in the handshake, not the CA. Saving what
`s_client` prints gives you the server certificate, which is the wrong thing
to trust. (For other servers whose chain does include the CA, `s_client
-showcerts` is fine.)

**Check what you got:**

```sh
openssl x509 -in harbor-ca.crt -noout -subject -issuer -enddate -fingerprint -sha256
# subject=CN=Harbor CA   (issuer = subject: it is the CA)

# it really signs Harbor's certificate: "Verify return code: 0 (ok)"
echo | openssl s_client -connect harbor.customer.local:443 -servername harbor.customer.local \
  -CAfile harbor-ca.crt 2>/dev/null | grep 'Verify return code'

# names the server certificate is valid for
echo | openssl s_client -connect harbor.customer.local:443 -servername harbor.customer.local 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

If `harbor.customer.local` is not in the subjectAltName list, clients fail with a
name mismatch even when the CA is trusted: fix `hostname` (or
`tlsCertificate.signingSettings.additionalDnsNames`) in `harbor-values.yaml`.

## 3. Jump host

```sh
# Ubuntu / Debian: system store (curl, git, helm, argocd, Go programs)
sudo cp harbor-ca.crt /usr/local/share/ca-certificates/harbor-customer.crt
sudo update-ca-certificates

# RHEL / Rocky
sudo cp harbor-ca.crt /etc/pki/ca-trust/source/anchors/harbor-customer.crt
sudo update-ca-trust

# Docker: per registry, no restart needed
sudo mkdir -p /etc/docker/certs.d/harbor.customer.local
sudo cp harbor-ca.crt /etc/docker/certs.d/harbor.customer.local/ca.crt

# Podman / Skopeo
sudo mkdir -p /etc/containers/certs.d/harbor.customer.local
sudo cp harbor-ca.crt /etc/containers/certs.d/harbor.customer.local/ca.crt

# vcf CLI (if it pulls plugins from Harbor)
vcf config cert add --host harbor.customer.local --ca-cert harbor-ca.crt
```

Check:

```sh
curl -s --noproxy '*' https://harbor.customer.local/api/v2.0/ping      # Pong, no -k
docker login harbor.customer.local -u <user>                           # Login Succeeded
```

## 4. VKS clusters

**Automatic.** Install Harbor before the clusters (README, step 2). A
cluster that existed before Harbor rolls its nodes once to pick up the CA.

**Check** with a pull from Harbor (the image pushed in README step 2, or any
other image in Harbor):

```sh
k() { kubectl --context customer-cluster-01:customer-cluster-01 "$@"; }
# VKS enforces Pod Security "restricted" in unlabelled namespaces, which
# rejects a plain `kubectl run`; use a throwaway namespace at "baseline".
k create namespace pull-test
k label namespace pull-test pod-security.kubernetes.io/enforce=baseline
k -n pull-test run harbor-pull-test --image=harbor.customer.local/library/nginxinc/nginx-unprivileged:1.27-alpine \
  --restart=Never --command -- sleep 30
k -n pull-test get pod harbor-pull-test                 # Running or Completed = trusted
k -n pull-test describe pod harbor-pull-test | tail -5  # x509 in the events = not trusted
k delete namespace pull-test
```

**Fallback, if it isn't trusted** (or for any other private registry): add
the CA to the Cluster, which rolls the nodes. In `cluster.yaml`, under
`osConfiguration`, uncomment the `trust` block and paste the PEM. To get it
indented correctly for that spot:

```sh
sed 's/^/                /' harbor-ca.crt
```

```yaml
        trust:
          additionalTrustedCAs:
          - caCert:
              content: |
                -----BEGIN CERTIFICATE-----
                ...
                -----END CERTIFICATE-----
```

Commit, push, then sync the cluster Application (manual sync) and watch the
rollout (`kubectl --context <sv> -n customer-ns get machines -w`).

## 5. ArgoCD (Helm charts or OCI from Harbor)

Only if Applications use Harbor as a Helm/OCI source; git repos don't need
it.

```sh
argocd cert add-tls harbor.customer.local --from harbor-ca.crt
# a Harbor project as a Helm OCI repository (robot account recommended):
argocd repo add harbor.customer.local/<project> --type helm --name harbor-<project> \
  --enable-oci --username '<robot-account>' --password <secret>
argocd repo list
```

## 6. Pods and private projects

Images from a **private** Harbor project need a pull secret, trust is not
enough. Create a robot account in the project (Projects > project > Robot
Accounts, permission Pull), then:

```sh
k -n <app-ns> create secret docker-registry harbor-pull \
  --docker-server=harbor.customer.local --docker-username='<robot-account>' --docker-password=<secret>
# use it in the pod spec: imagePullSecrets: [{name: harbor-pull}]
# or for every pod of the namespace's default ServiceAccount:
k -n <app-ns> patch serviceaccount default -p '{"imagePullSecrets":[{"name":"harbor-pull"}]}'
```

A pod that calls Harbor's API itself (not an image pull) needs the CA in its
own trust store, e.g. from a ConfigMap:

```sh
k -n <app-ns> create configmap harbor-ca --from-file=ca.crt=harbor-ca.crt
# mount it, and point the tool at it (SSL_CERT_FILE, REQUESTS_CA_BUNDLE, --cacert ...)
```

## 7. Browsers and laptops

```sh
# macOS
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain harbor-ca.crt
# Windows (admin PowerShell)
certutil -addstore -f Root harbor-ca.crt
```

macOS rejects server certificates valid for more than 825 days even from a
trusted CA ("not standards compliant"). Harbor's self-issued certificate is
valid much longer, so Docker and CLIs on a Mac may still fail; use the Linux
jump host for pushes, or give Harbor a certificate from the customer's CA.
