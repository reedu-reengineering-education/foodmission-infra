# foodmission-infra

Kubernetes infrastructure for FOODMISSION, managed via ArgoCD and Helm.

## Repository structure

```
apps/          ArgoCD Application manifests (one per env + observability)
charts/
  foodmission/ Main app chart — API, Keycloak, PostgreSQL (CNPG)
  observability/ Grafana, Prometheus, Loki, Tempo
cluster/       Hetzner k3s cluster config
secrets/       SealedSecrets (*.sealed.yaml committed, *.plain.yaml local only)
```

## Environments

| Environment | Namespace | ArgoCD app |
|---|---|---|
| Test | `foodmission-test` | `foodmission-test` |
| Staging | `foodmission-staging` | `foodmission-staging` |
| Production | `foodmission-prod` | `foodmission-prod` |

All environments auto-sync from `main` (with `selfHeal: true`). Pruning is **disabled** on app namespaces to protect the database.

---

## Access ArgoCD locally

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Then open https://localhost:8080. Get the initial admin password:

```bash
kubectl get secret -n argocd argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

## Deploying a new version

Update the image tag in the relevant values file, then open a pull request against `main`. ArgoCD syncs automatically once the PR is merged.

**API** — edit `api.image` in the env values file:

```yaml
# charts/foodmission/prod.values.yaml
api:
  image: ghcr.io/reedu-reengineering-education/foodmission-data-framework:<new-tag>
```

**Keycloak** — edit `keycloak.image` (for version upgrades see [Upgrading Keycloak](#upgrading-keycloak-majorminor-version)):

```yaml
# charts/foodmission/prod.values.yaml
keycloak:
  image: ghcr.io/reedu-reengineering-education/foodmission-keycloak:<new-tag>
```

Typical flow:
1. Update the tag in the appropriate `*.values.yaml`
2. Push a PR — CI runs `helm lint` and `helm template | kubeconform` checks
3. Merge to `main` — ArgoCD picks up the change within ~3 minutes

### Upgrading Keycloak (major/minor version)

Keycloak version upgrades run DB migrations, and those migrations often forbid
old and new pods running side by side. The realm JSON
(`charts/foodmission/files/foodmission-realm.production.json`) is only imported
into a **fresh** database (`--import-realm` skips existing realms), so realm
changes required by an upgrade must be applied by hand in every existing env.

1. **Dump the Keycloak DB** of the env: `./tools/db-dump.sh <env> keycloak`.
2. **Switch the Deployment to `Recreate`** so no two versions run at once:
   ```yaml
   keycloak:
     strategy:
       type: Recreate
   ```
   Envs synced with `ServerSideApply=true` (currently **test**) reject this
   change with `spec.strategy.rollingUpdate: Forbidden` because the defaulted
   `rollingUpdate` field stays on the live object. Patch it once before the
   sync; afterwards the env stays on `Recreate`:
   ```bash
   kubectl -n foodmission-<env> patch deploy foodmission-<env>-keycloak --type=json -p '[
     {"op":"remove","path":"/spec/strategy/rollingUpdate"},
     {"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'
   ```
   Envs using client-side apply (staging, prod) switch without the patch.
3. **Bump `keycloak.image`** together with any image-level settings, e.g.
   `keycloak.runAsUser: 2000` for images >= 0.1.3 (Keycloak 26.6+), which run as
   uid 2000. With uid 1000 startup fails with `AccessDeniedException` on
   `/opt/keycloak/lib/quarkus`.
4. **Apply realm changes** in the admin console of that env:
   - **Before the upgrade** (works on the old version too): `foodmission-api`
     client → Client scopes → `foodmission-api-dedicated` → Add mapper → By
     configuration → Audience, name `audience`, Included Client Audience
     `foodmission-api`, Add to access token + Add to token introspection on.
     26.6.2+ token introspection requires the introspecting client in `aud`;
     without it every authenticated API call gets 401.
   - **After the upgrade** (the scope is created by the 26.8.2 migration):
     `foodmission-service` client → Client scopes → Add client scope →
     `kc-admin-api` → **Default**. 26.8.2+ admin REST API audience check;
     without it the API gets 401 on user creation and execute-actions emails.
5. **Smoke test** against `https://<env-api-host>/api/v1`. Each step covers
   one upgrade risk:
   ```bash
   API=https://test.api.foodmission.eu/api/v1
   EMAIL=kc-smoke-$(date +%s)@<a-mailbox-you-can-read>
   # Keycloak pod Ready and no errors at startup (uid, DB migrations)
   kubectl -n foodmission-<env> logs deploy/foodmission-<env>-keycloak | grep -E 'ERROR|Listening on'
   # Register: API creates the user via the admin REST API as foodmission-service
   # (needs kc-admin-api scope; 401 otherwise)
   curl -sf -X POST $API/auth/register -H 'content-type: application/json' \
     -d "{\"username\":\"${EMAIL%@*}\",\"email\":\"$EMAIL\",\"password\":\"Smoke-test-123\"}"
   # Login (password grant) -> access + refresh token
   TOKENS=$(curl -sf -X POST $API/auth/login -H 'content-type: application/json' \
     -d "{\"username\":\"$EMAIL\",\"password\":\"Smoke-test-123\"}")
   AT=$(echo "$TOKENS" | jq -r .access_token); RT=$(echo "$TOKENS" | jq -r .refresh_token)
   # Authenticated call: API validates the token online via introspection
   # (needs foodmission-api audience mapper; 401 otherwise)
   curl -sf $API/auth/profile -H "authorization: Bearer $AT"
   # Refresh
   curl -sf -X POST $API/auth/refresh -H 'content-type: application/json' -d "{\"token\":\"$RT\"}" | jq -r '.access_token|length'
   # Password reset: always returns 200, so check that the email ARRIVES
   # (admin API execute-actions-email + SMTP; 26.8.1 no longer falls back
   # from starttls to plaintext). If not, check API logs for the warning.
   curl -sf -X POST $API/auth/password-reset -H 'content-type: application/json' -d "{\"email\":\"$EMAIL\"}"
   ```
   Then in a browser: sign in to the dashboard (e.g. test.data.foodmission.eu),
   which goes through the hosted Keycloak login page (custom theme renders,
   redirect back works). Finally delete the smoke-test user in the admin console.

   A wrong password now returns **400** `invalid_grant` from `/auth/login`
   (Keycloak 26.6+), not 401, because the API passes Keycloak's status through.

---

## Secrets

Secrets are managed with [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets).

### Initial Setup (One-Time)

Install the sealed-secrets controller once for the entire cluster:

```bash
# Add the Helm repository
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update

# Install cluster-wide controller
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --set fullnameOverride=sealed-secrets-controller
```

### Sealing Secrets

Only real secrets (passwords, client secrets, keys) belong here. Plain config
such as `LOG_LEVEL`, `NODE_ENV`, Keycloak URLs/IDs and SMTP host/sender is set in
the Helm values and rendered into `templates/app-configmap.yaml`.

1. Fill in real values in `secrets/<env>.plain.yaml` (never commit these)
2. Seal them using the cluster-wide controller:
   ```bash
   kubeseal \
     --controller-namespace=kube-system \
     --controller-name=sealed-secrets-controller \
     -f secrets/<env>.plain.yaml \
     -o yaml > secrets/<env>.sealed.yaml
   ```
3. Commit and push the `*.sealed.yaml` file

The controller watches all namespaces and will automatically unseal secrets when SealedSecret resources are created.

---

## Troubleshooting

### ArgoCD shows an app as OutOfSync / degraded

```bash
# Check app status
kubectl get application -n argocd

# Force a manual sync
argocd app sync foodmission-prod

# See what ArgoCD is trying to apply
argocd app diff foodmission-prod
```

### Pod is crashing

```bash
# List pods in an env
kubectl get pods -n foodmission-prod

# Logs for the API
kubectl logs -n foodmission-prod -l app=foodmission-api --tail=100

# Describe a pod for events
kubectl describe pod -n foodmission-prod <pod-name>
```

### Database issues (CNPG)

```bash
# Check cluster health
kubectl get cluster -n foodmission-prod

# Check pod logs
kubectl logs -n foodmission-prod -l cnpg.io/cluster=foodmission-pg-prod --tail=100

# Connect directly to the primary
kubectl cnpg psql -n foodmission-prod foodmission-pg-prod
```

### Roll back a deployment

Because ArgoCD tracks `main`, the fastest rollback is reverting the commit:

```bash
git revert HEAD
git push origin main
```

ArgoCD will sync the reverted state within a few minutes. Alternatively, pin a specific revision in ArgoCD's UI (`App Details → Edit → Target Revision`).

### Helm chart changes not taking effect

ArgoCD only re-renders templates when the Git revision changes. If you modified a values file and nothing happened, check:
- The commit is on `main` (ArgoCD ignores other branches)
- The app isn't suspended: `argocd app get foodmission-prod | grep Suspended`
- Trigger a manual refresh: `argocd app get foodmission-prod --refresh`
