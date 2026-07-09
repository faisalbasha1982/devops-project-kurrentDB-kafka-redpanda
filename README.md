# Aequor — crypto settlement & observability reference platform

A trade-capture → settlement → observability pipeline that mirrors an
institutional crypto exchange back-office:

- **KurrentDB** — immutable event log, the source of truth for every fill.
- **TigerBeetle** — double-entry ledger, the consistency-critical system of record.
- **Prometheus / InfluxDB** — timeseries store for SLOs and reconciliation health.
- **Redpanda (→ Confluent later)**, **EKS**, **Terraform/Terragrunt**, and
  **progressive delivery** wrap around that spine in later phases.

The invariant that ties it all together: balances derived from the KurrentDB
event log must always equal TigerBeetle's posted balances — `reconciliation_drift = 0`.

---

## Phase 0b — the platform layer (this repo, right now)

This is the datastore + observability foundation. The four pipeline services
(feed → capture → settlement → reconciler) arrive in Phase 0c.

### Prerequisites (inside WSL2 Ubuntu, repo at `~/aequor`)

- Docker Engine + `docker compose` v2
- `make`, `curl`
- ~12 GB free disk, WSL given ~8 GB RAM (see `.wslconfig` in the project notes)

### Bring it up

```bash
make init     # one-time: pull images + format the TigerBeetle data file
make up       # start everything
make ps       # all containers should be Up (redpanda: healthy)
make urls     # print the local URLs
make verify   # health-check each component
```

Give it ~30–60s after `make up` before `make verify` — KurrentDB and Redpanda
take a moment to become ready.

### What you should see

| Component        | URL / endpoint             | Check                                    |
|------------------|----------------------------|------------------------------------------|
| KurrentDB        | http://localhost:2113      | Admin UI loads; Stream Browser works     |
| TigerBeetle      | localhost:3000 (gRPC)      | `make tb-repl` connects                  |
| Redpanda Console | http://localhost:8080      | Broker shows healthy, 0 topics initially |
| Prometheus       | http://localhost:9090      | Status → Targets: prometheus is UP       |
| Grafana          | http://localhost:3001      | Prometheus datasource pre-wired          |

---

## Touch the three data models (the Phase 0 learning goal)

Do these by hand before we add code — it makes the later services obvious.

### 1. TigerBeetle — double-entry in 4 commands

```bash
make tb-repl
```

Inside the REPL, create two accounts on ledger 700 and move value between them:

```
create_accounts id=1 code=10 ledger=700 flags=history,
                id=2 code=10 ledger=700 flags=history;

create_transfers id=1 debit_account_id=1 credit_account_id=2 amount=100 ledger=700 code=10;

lookup_accounts id=1, id=2;
```

Account 1 now shows `debits_posted=100`, account 2 shows `credits_posted=100`.
That is the entire settlement primitive: a transfer debits one account and
credits another, atomically, and the ledger enforces that they balance. Type
`Ctrl-D` to exit.

> Two-phase transfers (`flags=pending` then a posting transfer) are how we make
> a multi-leg crypto settlement atomic — that's Phase 1.

### 2. KurrentDB — append an event, see the stream

Open http://localhost:2113 → **Stream Browser**. Or append over HTTP:

```bash
curl -i -X POST http://localhost:2113/streams/trade-demo \
  -H "Content-Type: application/vnd.kurrent.events+json" \
  -d '[{"eventId":"7b3c1e14-0000-0000-0000-000000000001",
        "eventType":"TradeExecuted",
        "data":{"symbol":"BTC-USD","side":"buy","qty":"0.5","price":"64000"}}]'
```

Then read it back:

```bash
curl -s http://localhost:2113/streams/trade-demo/0/forward/20 \
  -H "Accept: application/vnd.kurrent.atom+json" | head -c 800
```

The event is immutable and lives in its own stream (`trade-demo`). In the
pipeline, every fill becomes a `TradeExecuted` event in a per-trade stream.

### 3. Prometheus — confirm it's storing timeseries

http://localhost:9090 → **Status → Targets**. `prometheus` is UP; `redpanda`
and `kurrentdb` may need the path tweak noted in `prometheus.yml` (we finalize
scraping in Phase 0c). Run a query, e.g. `up`, in the Graph tab.

---

## Teardown

```bash
make down     # stop, keep data
make clean    # stop AND wipe all data (fresh start)
```

## Ports

| Port  | Service                    |
|-------|----------------------------|
| 2113  | KurrentDB UI + gRPC        |
| 3000  | TigerBeetle gRPC           |
| 8080  | Redpanda Console           |
| 19092 | Redpanda Kafka (external)  |
| 18081 | Redpanda Schema Registry   |
| 9644  | Redpanda admin / metrics   |
| 9090  | Prometheus                 |
| 3001  | Grafana (→ container 3000) |

## Phase 0c — the pipeline services

Four services turn the datastores into a live pipeline:

- `feed` — generates synthetic BTC-USD / ETH-USD fills to the Kafka topic `trades.fills`.
- `capture` — consumes fills and appends a `TradeExecuted` event to a per-trade
  KurrentDB stream (`trade-<id>`), idempotently (expected version NO_STREAM).
- `settlement` — subscribes to the event log and posts two *linked* transfers per
  fill to TigerBeetle (a quote leg + a base leg) so each settlement is atomic.
  Idempotent via deterministic transfer ids derived from the trade id.
- `reconciler` — every 10s replays the event log, recomputes what each ledger
  account should hold, compares to TigerBeetle, and exports
  `aequor_reconciliation_drift` (must be 0) to Prometheus.

### Run it

```bash
make up          # builds the four service images and starts them alongside the stack
make ps          # feed/capture/settlement/reconciler should be Up
```

First build takes a few minutes (pip install in each image). Then watch it work:

```bash
docker compose logs -f feed capture settlement reconciler
```

You want to see `feed` producing, `capture` capturing, `settlement` settling,
and `reconciler` printing `drift=0 [OK]`.

### Verify the invariant

In Prometheus (http://localhost:9090), query:

- `aequor_reconciliation_drift` → should be `0`
- `aequor_reconciliation_trades_counted` → climbs as fills flow
- `rate(aequor_settlements_total[1m])` → settlement throughput

Service metrics are also on http://localhost:8001/metrics (settlement) and
http://localhost:8002/metrics (reconciler).

### The point

`drift = 0` means the event log (source of truth) and the ledger (system of
record) agree, continuously verified. In Phase 5 this exact gauge becomes the
canary gate: a deploy that breaks settlement consistency spikes drift and the
rollout auto-aborts.

## Ledger model (Phase 0c)

Each asset is its own TigerBeetle ledger (USD=840, BTC=1001, ETH=1002). Two
entities — customer and venue — hold an account per asset. A buy debits the
customer's quote (USD) account / credits the venue, and debits the venue's base
(BTC) account / credits the customer; a sell reverses both. The two legs are
linked so they commit atomically. Two-phase *pending → posted* settlement (for
a trade lifecycle where settlement confirms later) is layered in Phase 1.

---

## Phase 2 — event-sourcing depth (KurrentDB)

### 2a — trade aggregate lifecycle
Settlement now emits a `TradeSettled` event back into the trade's stream after
posting to the ledger, so each trade is a real aggregate:
`trade-<id> = [TradeExecuted, TradeSettled]`. The append is idempotent — it
expects stream version 0 (only TradeExecuted present), so redelivery can't
double-record. This makes settlement lag directly countable from the log:
`aequor_unsettled_trades = TradeExecuted − TradeSettled` (exported by reconciler).

### 2b — persistent subscription + checkpointing
Settlement consumes via a **persistent subscription** (`settlement` group)
instead of a catch-up subscription. The server holds the checkpoint, so a
restart resumes where it left off rather than replaying the whole log. Each
event is `ack`-ed on success and `nack`-ed (retry) on failure. Subscription lag
(commit-position gap to the log head) is exported as
`aequor_settlement_subscription_lag`.

You can watch the checkpoint advance in the KurrentDB Admin UI
(http://localhost:2113 → Persistent Subscriptions → `settlement`).

### Run / verify

```bash
make up          # rebuilds settlement + reconciler
docker compose logs -f settlement reconciler
```

- settlement log: `created persistent subscription 'settlement'` then processing
- reconciler log: `trades=N settled=N unsettled=0 drift=0 [OK]`

New metrics in Prometheus (http://localhost:9090):
- `aequor_settlement_subscription_lag` — should hover near 0 when caught up
- `aequor_unsettled_trades` — spikes if settlement stops, returns to 0 on catch-up
- `aequor_settlements_nacked_total` — should stay 0 in the happy path

### The resumability experiment
`docker compose stop settlement`, let fills pile up, then `start` it. Because the
subscription is persistent, settlement resumes from its server checkpoint and
drains the backlog — watch `aequor_unsettled_trades` climb then fall to 0. On the
old catch-up subscription it would have re-read the entire log from position 0.

### 2c — projections (read models built inside the database)
Two **continuous KurrentDB projections** (JavaScript that runs *server-side*, in
the DB) fold the event log into read models:

- `aequor-settlement-status` — per-symbol `{executed, settled, unsettled}`.
  `TradeSettled` carries only transfer ids, so the projection keeps a small
  `pending` map (`trade_id → symbol`) to attribute a settle back to its symbol;
  that map drains to ~0 as settlement catches up, mirroring `aequor_unsettled_trades`.
- `aequor-volume-by-instrument` — per-symbol cumulative fills, base qty, and
  quote-notional.

A `projection` service (`services/projection/`) owns their lifecycle: it registers
them idempotently (`create_projection`; `update_projection` if they already exist;
then `enable_projection`), then every 5s reads `get_projection_state()` and
`get_projection_statistics()` and exports:

- read model: `aequor_projection_symbol_executed|settled|unsettled{symbol}`,
  `aequor_projection_symbol_volume_qty|notional{symbol}`.
- health/lag: `aequor_projection_progress_percent`, `aequor_projection_lag_bytes`
  (log-head commit position − projection position), `aequor_projection_running`,
  `aequor_projection_events_processed_after_restart`.

The projection is a *derived* read model — it never writes TigerBeetle and never
appends events, so it can't affect settlement idempotency or `drift`. Falling
behind shows up purely as projection lag (an SLO signal).

Inspect it in the Admin UI (http://localhost:2113 → **Projections** →
`aequor-settlement-status` → *State*), on `http://localhost:8003/metrics`, or in
Prometheus: `aequor_projection_symbol_unsettled`. The fold logic has an offline
check: `node services/projection/test_projection.mjs`.

### 2d — DR: rebuild-from-log, backup runbook, lag SLO
- `services/rebuild/` reconstructs the settlement-status read model from nothing
  but the event log (a catch-up `read_all()`), proving the log is a sufficient
  source of truth — the core disaster-recovery property. Run it standalone:
  `docker compose run --rm rebuild`.
- `docs/DR.md` — KurrentDB backup/restore, archiving & retention, and the
  read-model rebuild procedure.
- `observability/prometheus/rules/` — projection-lag recording rules + a
  multi-window burn-rate alert (wired in Phase 3).
