# InfluxDB operational telemetry side-path (Phase 3)

Prometheus is Aequor's SLO/alerting store — pull-based, aggregate, cheap to keep.
InfluxDB is a deliberately separate side-path for **high-frequency operational
telemetry** (tick-to-trade latency per instrument): push-based, high-volume, kept
at full resolution only briefly and then downsampled. Two stores, two jobs — this
mirrors a real trading platform and exercises the InfluxDB-specific skills.

## What runs

- `influxdb` (compose) — InfluxDB 2.7, org `aequor`, admin token `aequor-dev-token`,
  UI at http://localhost:8086.
- `telemetry` (compose) — writes ~20 Hz/symbol `tick_latency` points, ensures the
  two buckets, and installs the downsampling task.

## Tag-cardinality management (the trap)

Series cardinality = the product of all tag-value combinations. Tags are
**indexed**; fields are not. Tagging by an unbounded dimension
(`trade_id`, `order_id`, `user_id`) makes cardinality grow without bound and is
the canonical way to melt InfluxDB.

Aequor's discipline, enforced in `services/telemetry/main.py`:

| dimension            | where it goes | why                                   |
|----------------------|---------------|---------------------------------------|
| `symbol`, `side`, `venue` | **tag**  | bounded, low-cardinality, queried-by  |
| `latency_ms`         | **field**     | the measured value                    |
| `seq` (identifier)   | **field**     | high-cardinality — must NOT be a tag  |

Total series stays ≈ `|symbol| × |side| × |venue|` = 2 × 2 × 1 = 4. Audit it with
QUERY 3 in `queries.flux` (`schema.cardinality`); if it climbs, a bad tag crept in.

## Retention + downsampling

| bucket                   | retention | contents                         |
|--------------------------|-----------|----------------------------------|
| `telemetry_raw`          | 24h       | full-resolution `tick_latency`   |
| `telemetry_downsampled`  | 30d       | 1m `tick_latency_1m` rollups     |

`downsample.flux` is the rollup task (1-minute means per symbol/side). The
`telemetry` service installs it via the API on startup; to apply it by hand:

```bash
docker exec -it aequor-influxdb \
  influx task create --org aequor --file /dev/stdin < observability/influxdb/downsample.flux
```

Dashboards and analytics should read the **downsampled** bucket (cheap, long-lived);
only ad-hoc, recent, high-resolution questions hit the raw bucket.

## Flux vs PromQL

Same telemetry, two query languages by design — see `queries.flux` for Flux
(pipe-forward, `aggregateWindow`, `quantile`, `schema.cardinality`) against the
PromQL SLO rules in `../prometheus/rules/`. Practising both is the point.
