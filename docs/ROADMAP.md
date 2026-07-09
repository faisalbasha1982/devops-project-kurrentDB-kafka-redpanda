# Roadmap

The project is built in phases. Each phase is runnable on its own and maps to a
slice of the target job descriptions (crypto-exchange SRE / platform / operational
excellence). "Done" means it runs end-to-end with the reconciliation invariant
(`aequor_reconciliation_drift = 0`) green.

## Phase 0 — platform + pipeline — DONE
- **0b** platform layer: KurrentDB, TigerBeetle, Redpanda (+Console), Prometheus,
  Grafana on one host via docker-compose.
- **0c** pipeline services: feed → capture → settlement → reconciler, with the
  reconciliation invariant exported to Prometheus.

## Phase 1 — ledger lifecycle depth — DONE
- **richer chart of accounts**: per-asset customer, venue, **fee** (venue income)
  and **clearing/suspense** (crypto custody in-flight) accounts —
  `services/common/model.py`.
- **two-phase settlement**: every movement is a TigerBeetle `PENDING` →
  `POST_PENDING_TRANSFER` pair, the whole set LINKED so a multi-leg settlement is
  reserved then confirmed atomically. The crypto leg passes through the clearing
  account; the customer pays a fee (`FEE_BPS`) to the venue fee account.
- **idempotency/dedup on the `id` field**: transfer ids are a deterministic hash
  of (trade, movement, phase); redelivery is a no-op (LINKED atomicity means the
  first pending id existing implies the whole chain committed).
- reconciliation recomputes **posted** balances from the log and holds
  `aequor_reconciliation_drift = 0`; a PENDING→POSTED pair nets to one posted
  movement, so the fuller model doesn't perturb the invariant.
- unit tests: `services/common/test_model.py` (double-entry per ledger, clearing
  nets to zero, deterministic/unique ids, fee + scaling exactness).
- SLO recording rules over settlement latency + error budgets land in Phase 3.

## Phase 2 — event-sourcing depth (KurrentDB) — IN PROGRESS
- **2a** DONE: trade aggregate lifecycle — settlement emits `TradeSettled` back
  into the trade stream; `aequor_unsettled_trades` exported.
- **2b** DONE: persistent subscription with server-side checkpointing + ack/nack;
  `aequor_settlement_subscription_lag` exported.
- **2c** DONE: KurrentDB **Projections** (JavaScript running in the DB) build read
  models from the event log — settlement status per symbol and volume per
  instrument. A `projection` service registers them idempotently
  (`create_projection`/`update_projection`/`enable_projection`), polls
  `get_projection_state`, and exports the read model plus projection progress and
  processing lag (`aequor_projection_*`) to Prometheus.
- **2d** DONE: **backup & DR** — `rebuild` tool reconstructs the read model purely
  from the event log via a catch-up read (`services/rebuild/main.py`); KurrentDB
  backup/restore + archiving/retention runbook in `docs/DR.md`; projection-lag
  recording rules + burn-rate alert in `observability/prometheus/rules/`.

## Phase 3 — timeseries & SLOs — DONE
- PromQL recording rules + multi-window burn-rate alerts on four SLOs —
  consistency (drift), settlement latency p99, projection freshness, and Kafka
  consumer lag — in `observability/prometheus/rules/` (`slo.yml`,
  `projection_lag.yml`). Settlement now exports `aequor_settlement_latency_seconds`.
- InfluxDB 2.x side-path (`influxdb` + `telemetry` services) for high-frequency
  operational telemetry: Flux downsampling task + example Flux queries
  (`observability/influxdb/`), strict tag-cardinality discipline (identifiers are
  fields, not tags), and raw(24h)/downsampled(30d) retention buckets.

## Phase 4 — platform / IaC — PLANNED
- Lift to EKS via Terraform + Terragrunt (multi-env, remote state, IRSA, Karpenter).
- Confluent-for-Kubernetes (CFK) operator replaces local Redpanda.
- Helm charts per service; Terratest / checkov / tflint in CI.
- Rehearse locally with kind/k3d before real EKS.

## Phase 5 — progressive delivery + chaos — DONE (authored; needs a cluster to run)
- Argo Rollouts canary on settlement (`argo/rollouts/`), gated on a background
  `AnalysisTemplate`: `aequor_reconciliation_drift == 0` (hard gate,
  `failureLimit: 0`) plus the settlement latency SLO. A bad deploy that breaks
  consistency auto-aborts before it settles a full share of trades.
- Chaos drills (`chaos/`): scripts + Chaos Mesh manifest to kill a TigerBeetle
  replica and a KurrentDB node, with a runbook mapping signals
  (`drift`, `unsettled_trades`, `subscription_lag`) to expected VSR/cluster
  behavior and recovery — both `--k8s` and `--compose` variants.
- `docs/POSTMORTEM.md`: a blameless postmortem of an injected fee-rounding
  regression the canary auto-aborted on drift — the whole design paying off.
