# Aequor — Helm (Phase 4)

One **parametrized** chart, `charts/aequor-service`, renders every Aequor app
service. The `service` value selects the image (`ghcr.io/aequor/aequor-<service>`,
all built from the single `services/Dockerfile`), sets the `SERVICE` env var, and
toggles the metrics `Service` + Prometheus-Operator `ServiceMonitor`. This is the
Kubernetes equivalent of the six compose services.

## Chart contents

```
charts/aequor-service/
  Chart.yaml
  values.yaml               # defaults (describe `settlement`)
  templates/
    _helpers.tpl
    deployment.yaml
    service.yaml            # only when metrics.enabled
    serviceaccount.yaml     # optional IRSA annotation
    servicemonitor.yaml     # only when metrics.enabled AND serviceMonitor.enabled
    NOTES.txt
envs/dev/values-<service>.yaml   # per-service overrides
```

## Compose → Helm mapping

| compose service | metrics | Helm values file            | notes |
|-----------------|:-------:|-----------------------------|-------|
| feed            |   no    | `values-feed.yaml`          | producer only, no Service |
| capture         |   no    | `values-capture.yaml`       | consumer + KurrentDB writer |
| settlement      |  yes    | `values-settlement.yaml`    | IRSA (aequor-app S3 role) |
| reconciler      |  yes    | `values-reconciler.yaml`    | exports `aequor_reconciliation_drift` |
| projection      |  yes    | `values-projection.yaml`    | KurrentDB projections read model |
| telemetry       |  yes    | `values-telemetry.yaml`     | InfluxDB; token via Secret `aequor-influx` |

`mem_limit: 256m` from compose maps to `resources.limits.memory: 256Mi`.
Datastore endpoints (`KURRENTDB_URI`, `TB_ADDRESSES`) point at the in-cluster
StatefulSet services; `KAFKA_BOOTSTRAP` points at the CFK Kafka (`confluent/cfk`).

## Install order

Datastores + Kafka first, then the pipeline (same dependency order as compose):

```bash
kubectl create namespace aequor

# 1. datastores (StatefulSets) + CFK Kafka — see confluent/cfk/README.md
# 2. telemetry token secret
kubectl -n aequor create secret generic aequor-influx \
  --from-literal=INFLUX_TOKEN=<token>

# 3. app services
for s in feed capture settlement reconciler projection telemetry; do
  helm upgrade --install aequor-$s charts/aequor-service \
    -n aequor -f envs/dev/values-$s.yaml
done
```

## Lint / render locally

```bash
helm lint charts/aequor-service -f envs/dev/values-settlement.yaml
helm template aequor-settlement charts/aequor-service \
  -n aequor -f envs/dev/values-settlement.yaml
```

CI (`.github/workflows/ci-helm.yml`) lints + templates the chart against every
env values file and validates the rendered manifests with `kubeconform`.

## IRSA

`values-settlement.yaml` carries the `eks.amazonaws.com/role-arn` annotation for
the `aequor-app` role (Terraform `modules/addons`). The role trusts both the
`aequor-settlement` and `aequor-rebuild` ServiceAccounts, so the DR rebuild job
reuses it for S3 chunk restore.
