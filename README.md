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

**Keycloak** — edit `keycloak.image`:

```yaml
# charts/foodmission/prod.values.yaml
keycloak:
  image: ghcr.io/reedu-reengineering-education/foodmission-keycloak:<new-tag>
```

Typical flow:
1. Update the tag in the appropriate `*.values.yaml`
2. Push a PR — CI runs `helm lint` and `helm template | kubeconform` checks
3. Merge to `main` — ArgoCD picks up the change within ~3 minutes

---

## Secrets

Secrets are managed with [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets).

### Initial Setup (One-Time)

Install the sealed-secrets controller once for the entire cluster:

```bash
# Add the Helm repository
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

# Install cluster-wide controller
helm install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --set fullnameOverride=sealed-secrets-controller
```

### Sealing Secrets

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
