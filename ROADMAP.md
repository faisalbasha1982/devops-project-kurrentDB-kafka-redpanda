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

## Phase 1 — ledger lifecycle depth — DEFERRED (carry-forward)
Intentionally skipped for now; independent of Phase 2. When picked up:
- two-phase settlement lifecycle: pending → posted transfers (trade executed now,
  settlement confirmed later) using TigerBeetle `PENDING` / `POST_PENDING_TRANSFER`.
- richer chart of accounts: fee accounts, clearing/suspense accounts per venue.
- SLO recording rules over settlement latency + error budgets.

## Phase 2 — event-sourcing depth (KurrentDB) — IN PROGRESS
- **2a** DONE: trade aggregate lifecycle — settlement emits `TradeSettled` back
  into the trade stream; `aequor_unsettled_trades` exported.
- **2b** DONE: persistent subscription with server-side checkpointing + ack/nack;
  `aequor_settlement_subscription_lag` exported.
- **2c** TODO: a KurrentDB **Projection** (JavaScript running in the DB) that
  builds a read model — e.g. settlement status per symbol, or an unsettled index.
  Register via `create_projection`, query via `get_projection_state`, expose lag.
- **2d** TODO: **backup & DR** — a catch-up-subscription rebuild tool that
  reconstructs a read model (or re-derives ledger state) purely from the event
  log; document the KurrentDB backup procedure; add projection-lag recording rules.

## Phase 3 — timeseries & SLOs — PLANNED
- PromQL recording rules + multi-window burn-rate alerts; error budgets on drift,
  settlement latency, subscription lag.
- InfluxDB side-path for high-frequency operational telemetry to practice Flux,
  tag-cardinality management, and retention + downsampling policies.

## Phase 4 — platform / IaC — PLANNED
- Lift to EKS via Terraform + Terragrunt (multi-env, remote state, IRSA, Karpenter).
- Confluent-for-Kubernetes (CFK) operator replaces local Redpanda.
- Helm charts per service; Terratest / checkov / tflint in CI.
- Rehearse locally with kind/k3d before real EKS.

## Phase 5 — progressive delivery + chaos — PLANNED
- Argo Rollouts / Flagger canary on settlement, gated on the drift + latency SLO
  (the payoff: a bad deploy that breaks consistency auto-aborts).
- Kill a TigerBeetle replica and a KurrentDB node to demonstrate fault tolerance
  and a DR runbook; write one real postmortem from an injected failure.
