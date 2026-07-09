# CLAUDE.md — Aequor

Context for Claude Code. Read this before making changes.

## What this is

Aequor is a reference **crypto-exchange settlement & observability platform**,
built as portfolio/interview material (target: Aquanow Senior Operational
Excellence Engineer, and similar SRE/platform roles). It is a real, running
system — not a slideware demo.

The spine, and the one sentence that explains the whole project:

> A trade's life is **event → ledger → metric**. KurrentDB is the immutable
> source of truth (every fill is an event), TigerBeetle is the
> consistency-critical system of record (each event settles as double-entry
> debits/credits), and a continuously-verified invariant —
> `aequor_reconciliation_drift = 0` — proves the two always agree.

That drift gauge is the point of the project. Everything protects it. In a
later phase it becomes the canary gate that auto-rolls-back a bad deploy.

## Architecture

```
feed → Kafka(Redpanda) → capture → KurrentDB(event log) → settlement → TigerBeetle(ledger)
                                          │                                      │
                                          └────────── reconciler ───────────────┘
                                                          │
                                             Prometheus ← metrics ← (all services)
```

- **feed** — synthetic BTC-USD / ETH-USD fills → Kafka topic `trades.fills`.
- **capture** — consumes fills, appends `TradeExecuted` to per-trade KurrentDB
  stream `trade-<id>` (idempotent via expected version NO_STREAM).
- **settlement** — persistent subscription to `TradeExecuted`; posts two *linked*
  transfers (quote + base leg) to TigerBeetle atomically, then appends
  `TradeSettled` back to the trade stream. Idempotent via deterministic transfer
  ids + version-gated append.
- **reconciler** — replays the event log every 10s, recomputes expected ledger
  balances, compares to TigerBeetle, exports `aequor_reconciliation_drift`.

## Repo layout

```
docker-compose.yml         # the whole stack, one container per component
Makefile                   # init / up / down / verify / tb-repl / clean
observability/             # prometheus.yml + grafana datasource provisioning
services/
  common/model.py          # THE ledger model — shared by settlement & reconciler
  feed|capture|settlement|reconciler/main.py
  Dockerfile               # single parametrized image (ARG SERVICE)
  requirements.txt         # pinned, verified deps
docs/ROADMAP.md            # phase status + what's next
docs/ENVIRONMENT.md        # WSL2/Docker setup + every gotcha already solved
data/tigerbeetle/          # TB data file lives here (gitignored, formatted by `make init`)
```

## Run

```bash
make init    # one-time: pull images + format the TigerBeetle data file
make up      # build service images + start everything
make verify  # health-check
```
Prometheus http://localhost:9090 · Grafana http://localhost:3001 · KurrentDB
http://localhost:2113 · Redpanda Console http://localhost:8080. Full port table
in docs/ENVIRONMENT.md.

## Pinned, verified versions (do not bump blindly)

- Images: `docker.kurrent.io/kurrent-latest/kurrentdb:latest`,
  `ghcr.io/tigerbeetle/tigerbeetle:latest`, `docker.redpanda.com/redpandadata/redpanda:latest`,
  `docker.redpanda.com/redpandadata/console:latest`, `prom/prometheus:latest`,
  `grafana/grafana:latest`.
- Python: `tigerbeetle==0.17.9`, `kurrentdbclient==1.3.3`, `confluent-kafka==2.15.0`,
  `prometheus-client>=0.20,<1`.

## Ledger model (services/common/model.py — the contract)

- Each **asset is its own TigerBeetle ledger**: USD=840, BTC=1001, ETH=1002.
  A transfer's debit and credit accounts must share a ledger, so a
  cross-currency trade spans two ledgers (quote + base).
- Four **entities** per asset: customer=1, venue=2, fee=3, clearing=4.
  `account_id = entity*10 + asset_index` (customer USD=11, venue BTC=22,
  fee USD=31, clearing BTC=42). `all_accounts()` = 4×3 = 12 accounts.
- **Amounts are integer minor units** (u128, no decimals): USD in cents (×100),
  crypto in ×1e8. `compute_postings()` does the scaling and returns **movements**.
- A fill = quote leg (customer↔venue) + base leg **through the clearing/suspense
  account** + a fee (customer→fee, `FEE_BPS`=10 bps of quote notional).
- **Two-phase**: each movement is a `PENDING` then `POST_PENDING_TRANSFER`; the
  whole set is `LINKED` (only the final transfer clears LINKED) so settlement is
  reserved-then-confirmed atomically, all-or-nothing.
- **Deterministic transfer ids**: `sha256(f"{trade_id}:{name}:{phase}")[:16]` →
  idempotency for free. LINKED atomicity means the first pending id existing
  implies the whole chain committed, so `lookup_transfers([first_pending])` is a
  safe idempotency gate.
- A PENDING→POSTED pair nets to exactly one **posted** movement, so reconciliation
  (which compares posted balances) is unperturbed: `drift = 0` holds.
- Tests: `python services/common/test_model.py`.

## Event model

- Per-trade streams: `trade-<id> = [TradeExecuted, TradeSettled]`.
- settlement consumes a **persistent subscription** (group `settlement`) filtered
  to `TradeExecuted` — server-side checkpoint, ack on success, nack(retry) on error.

## SDK gotchas already learned (don't rediscover these)

- TigerBeetle create results expose `.status` (enum) + `.timestamp`, NOT
  `.result`/`.index`. Success = `CREATED`, idempotent dup = `EXISTS`.
- TigerBeetle image is distroless — binary is at `/tigerbeetle`, not on PATH.
  REPL: `docker exec -it aequor-tigerbeetle /tigerbeetle repl --cluster=0 --addresses=3000`.
- `tb.id()` returns a fresh time-based u128 int. Flags are IntFlag (`A | B`).
- KurrentDB idempotent capture uses `WrongCurrentVersionError`; persistent-sub
  create uses `AlreadyExistsError`.
- cluster id 0 is dev/testing only (harmless warning locally).

## Working agreement for Claude Code

1. **Verify SDK APIs before writing client code.** These libraries are niche and
   fast-moving. Create a throwaway venv, `pip install` the pinned versions, and
   introspect the real signatures/enums rather than guessing. This has already
   caught real bugs.
2. **Keep the invariant green.** `aequor_reconciliation_drift` must stay 0.
   Any change that could affect settlement or the ledger model must be reasoned
   about against reconciliation.
3. **Don't break idempotency.** Deterministic transfer ids and version-gated
   appends are load-bearing. Redelivery must never double-post.
4. **Unit-test the ledger model** (`services/common/model.py`) when you touch it:
   per-ledger debits must equal credits; ids must be deterministic; scaling exact.
5. **Prefer minimal diffs.** This runs on a resource-limited WSL2 laptop; keep the
   footprint small (`mem_limit` on services, single-node datastores).
6. Read docs/ENVIRONMENT.md before debugging startup failures — the io_uring,
   seccomp, aio-max-nr, and mount issues are all already solved there.

## Current status

Phases 0, 1, and 2 (2a–2d) are complete. Phase 1 added the fuller chart of
accounts + two-phase settlement; Phase 2c/2d added KurrentDB projections, a
rebuild-from-log DR tool, and projection-lag SLO rules. Phases 3 (PromQL/InfluxDB
SLOs), 4 (EKS/Terraform/Terragrunt/Helm/CFK), and 5 (Argo Rollouts canary +
chaos + postmortem) are authored under `observability/`, `terraform/`, `helm/`,
`argo/`, `chaos/`, and `.github/`. The infra phases are best-practice code that
requires a real AWS/EKS cluster to `apply`/deploy — validated with fmt/lint,
not a live cluster. See docs/ROADMAP.md for the full plan.
