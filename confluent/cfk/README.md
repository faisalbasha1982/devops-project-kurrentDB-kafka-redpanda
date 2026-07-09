# Confluent for Kubernetes (CFK) — Kafka on EKS

Phase 4 swaps the local single-node **Redpanda** broker for a real Kafka cluster
managed by the **Confluent for Kubernetes** operator. The wire protocol is
identical, so the app services are unchanged — only `KAFKA_BOOTSTRAP` moves from
`redpanda:9092` to `kafka.confluent.svc.cluster.local:9092` (set in the Helm env
values files).

## Install the operator (Helm)

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update

kubectl create namespace confluent
helm upgrade --install confluent-operator \
  confluentinc/confluent-for-kubernetes \
  -n confluent --version 0.1021.28
```

Pin the chart version (no `latest`); `0.1021.x` ships the CRDs used by the CRs
here (`platform.confluent.io/v1beta1`).

## Apply the cluster + topic

```bash
# 1. KRaft controller quorum + broker cluster
kubectl apply -f kafka.yaml

# wait for brokers to be Ready
kubectl -n confluent get pods -w

# 2. the pipeline topic
kubectl apply -f topic-trades-fills.yaml
kubectl -n confluent get kafkatopic trades-fills
```

## CRs

| File                       | Kind             | Purpose |
|----------------------------|------------------|---------|
| `kafka.yaml`               | `KRaftController` + `Kafka` | 3-node KRaft controller quorum + 3-broker cluster (no ZooKeeper), gp3 storage. |
| `topic-trades-fills.yaml`  | `KafkaTopic`     | `trades.fills`, 6 partitions, RF 3, `min.insync.replicas=2`, 7-day retention. |

## Notes

- **RF 3 / min.insync 2**: tolerates one broker (one AZ) failing without data
  loss or producer stalls. The durable system of record is still KurrentDB —
  Kafka is the transport, so 7-day retention is plenty.
- The object name `trades-fills` differs from the topic name `trades.fills`
  because Kubernetes object names can't contain dots; `spec.name` carries the
  real topic name the services read via `TOPIC=trades.fills`.
- CFK also offers `Connect`, `SchemaRegistry`, and `KafkaRestProxy` CRs; none are
  needed for the Aequor pipeline, so they're intentionally omitted.
