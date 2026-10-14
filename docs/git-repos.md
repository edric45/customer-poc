# Adding the customer's git repository to ArgoCD

How ArgoCD gets read access to the repo that holds these files (or any app
repo), when it is private, on GitHub or GitLab, behind the proxy.

Placeholders: `<repo-url>` is the clone URL exactly as GitHub/GitLab shows
it (ending in `.git`); `git.customer.local` the git server; `customer-ns` ArgoCD's
namespace. Run from the jump host after `argocd login` (README, step 3.2).

## 1. Pick a method

| Method | When | Works through an HTTP proxy |
|---|---|---|
| HTTPS + access token | default; GitHub or GitLab, cloud or self-hosted | yes |
| HTTPS credential template | several repos under one GitLab group / GitHub org share one token | yes |
| SSH deploy key | the git server only allows SSH, or tokens are not allowed | **no**: SSH only goes through a SOCKS5 proxy (`--proxy socks5://...`). Use it for internal git servers ArgoCD reaches directly |

Always read-only. ArgoCD never pushes to git.

## 2. Create the credential

### GitHub (github.com or GitHub Enterprise)

Fine-grained personal access token, scoped to the one repo:

1. GitHub > Settings > Developer settings > Personal access tokens >
   Fine-grained tokens > Generate new token.
2. Resource owner: the org. Repository access: Only select repositories >
   `customer-poc`.
3. Permissions: Repository > **Contents: Read-only** (Metadata: Read-only is
   added automatically).
4. Set an expiry; note the date (an expired token shows as "authentication
   required" in ArgoCD).

The org may need to approve fine-grained tokens first. Username for ArgoCD:
any non-empty string, e.g. `git`.

### GitLab (gitlab.com or self-managed)

Either of these, both read-only:

- **Deploy token** (per project or group): Project > Settings > Repository >
  Deploy tokens > Add token, scope **read_repository**. GitLab shows a
  username (`gitlab+deploy-token-N`) and the token: use both.
- **Project / group access token**: Project > Settings > Access tokens, role
  **Reporter**, scope **read_repository**. Username: any non-empty string,
  e.g. `oauth2`.

Use the `.git` clone URL: `https://git.customer.local/platform/customer-poc.git`.

### SSH deploy key (either)

```sh
ssh-keygen -t ed25519 -N '' -C argocd-customer -f ~/argocd-customer
cat ~/argocd-customer.pub
```

Add the `.pub` as a **read-only deploy key**: GitHub repo > Settings > Deploy
keys; GitLab project > Settings > Repository > Deploy keys. The private key
goes only into ArgoCD (below), then delete it from the jump host.

## 3. Before adding: proxy and certificates

**Proxy.** ArgoCD's repo server uses the proxy from `supervisor/argocd/argocd.yaml`
(`spec.repo.proxy`) for every repo, except hosts in its `noProxy`
(`.customer.local` is). So:

- github.com / gitlab.com: through the proxy, nothing more to do.
- an internal GitLab under `.customer.local`: direct, nothing more to do.
- anything else internal: add it to `noProxy` in `argocd.yaml`, or override
  per repo with `--proxy` / `--no-proxy` on `argocd repo add`.

**Private CA on the git server** (self-managed GitLab with an internal
certificate). Give ArgoCD the CA before adding the repo:

```sh
# get the CA from your PKI team, or see docs/harbor-trust.md section 2 for openssl commands
argocd cert add-tls git.customer.local --from git-ca.crt
argocd cert list --cert-type https
```

**SSH host key** (SSH method only):

```sh
ssh-keyscan git.customer.local | argocd cert add-ssh --batch
# non-standard port:
ssh-keyscan -p 2222 git.customer.local | argocd cert add-ssh --batch
argocd cert list --cert-type ssh
```

## 4. Add the repository

HTTPS + token (GitHub or GitLab):

```sh
argocd repo add <repo-url> --username <username> --password <token>
```

Credential template (one token for every repo under a prefix). Repos added
later under that prefix need no credentials:

```sh
argocd repocreds add https://git.customer.local/platform/ --username <username> --password <token>
argocd repo add https://git.customer.local/platform/customer-poc.git
argocd repocreds list
```

SSH:

```sh
argocd repo add git@git.customer.local:platform/customer-poc.git --ssh-private-key-path ~/argocd-customer
shred -u ~/argocd-customer          # the key now lives only in ArgoCD
```

Without the CLI (the same thing ArgoCD stores): a Secret in customer-ns with a
label. Create it with kubectl, **never commit it**:

```sh
kubectl --context <sv> -n customer-ns create secret generic repo-customer-poc \
  --from-literal=type=git \
  --from-literal=url=<repo-url> \
  --from-literal=username=<username> \
  --from-literal=password=<token>
kubectl --context <sv> -n customer-ns label secret repo-customer-poc argocd.argoproj.io/secret-type=repository
```

## 5. Check

```sh
argocd repo list                  # CONNECTION STATUS: Successful
argocd repo get <repo-url>
```

UI: Settings > Repositories, "Successful" with a green tick.

## 6. Point the manifests at the repo

Every Application and ApplicationSet carries the URL (marked `# CHANGE`):

```sh
grep -rn '# CHANGE' supervisor/applications supervisor/applicationsets
# replace in place (GNU sed on the jump host):
sed -i 's#https://git.customer.local/platform/customer-poc.git#<repo-url>#' \
  supervisor/applications/*.yaml supervisor/applicationsets/*.yaml
git commit -am "Point ArgoCD at the customer repo" && git push
```

The URL in the manifests must match the added repo exactly (same scheme,
same `.git` suffix), or ArgoCD treats it as a different, credential-less repo.

## 7. When it fails

| `argocd repo add` / Application error | Cause | Fix |
|---|---|---|
| `authentication required` | wrong or expired token, wrong username for a deploy token | new token; `argocd repo add ... --upsert` |
| `repository not found` | token lacks access to this repo, or URL without `.git` (GitLab) | token scope; exact clone URL |
| `x509: certificate signed by unknown authority` | private CA on the git server | `argocd cert add-tls` (section 3) |
| `i/o timeout`, `proxyconnect tcp` | proxy missing or wrong, or an internal host sent to the proxy | `spec.repo.proxy` / `noProxy` in argocd.yaml; `--proxy` / `--no-proxy` per repo |
| `knownhosts: key is unknown` | SSH host key not added | `ssh-keyscan ... \| argocd cert add-ssh --batch` |
| `ssh: handshake failed` through the proxy | SSH can't use an HTTP proxy | use HTTPS + token |
| Application: `repository not accessible` while `repo list` is Successful | the Application's `repoURL` differs from the added URL | make them identical (section 6) |

Logs of the component that clones:

```sh
kubectl --context <sv> -n customer-ns logs deploy/argocd-repo-server --tail=100
```

## 8. Rotate or remove

```sh
argocd repo add <repo-url> --username <username> --password <new-token> --upsert
argocd repo rm <repo-url>
argocd repocreds rm https://git.customer.local/platform/
```
