# Observability Stack

Cluster-wide observability with Grafana, Prometheus, Loki, and Tempo.

## Access

**Grafana URL:** https://grafana.foodmission.eu

**Get admin password:**
```bash
kubectl get secret -n observability observability-grafana -o jsonpath='{.data.admin-password}' | base64 -d
```

## Components

| Component | Purpose | Internal URL |
|-----------|---------|--------------|
| Grafana | Dashboards | `observability-grafana.observability.svc:80` |
| Prometheus | Metrics | `observability-prometheus-server.observability.svc:80` |
| Loki | Logs | `observability-loki.observability.svc:3100` |
| Tempo | Traces | `observability-tempo.observability.svc:3100` |
