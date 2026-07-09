// Aequor — example Flux queries for the operational telemetry side-path.
// Paste into the InfluxDB Data Explorer (http://localhost:8086) or run with
//   influx query --org aequor --file <(sed -n '/QUERY N/,/^$/p' this_file)
// (each query is standalone; run one at a time).

// QUERY 1 — p99 tick-to-trade latency per symbol over the last 15m (raw bucket).
// The high-resolution question Prometheus is a poor fit for.
from(bucket: "telemetry_raw")
    |> range(start: -15m)
    |> filter(fn: (r) => r._measurement == "tick_latency" and r._field == "latency_ms")
    |> group(columns: ["symbol"])
    |> quantile(q: 0.99, method: "estimate_tdigest")

// QUERY 2 — 1m mean latency trend from the DOWNSAMPLED bucket (cheap, long-lived).
// This is what a dashboard should read, not the raw firehose.
from(bucket: "telemetry_downsampled")
    |> range(start: -6h)
    |> filter(fn: (r) => r._measurement == "tick_latency_1m")
    |> group(columns: ["symbol", "side"])

// QUERY 3 — CARDINALITY AUDIT. Series cardinality is the InfluxDB failure mode;
// watch it. This counts distinct series in the raw bucket. If it climbs without
// bound, a high-cardinality tag has crept in (the classic mistake: tagging by
// trade_id / order_id). It should stay ~= |symbol| x |side| x |venue|.
import "influxdata/influxdb/schema"

schema.cardinality(bucket: "telemetry_raw", start: -1h)

// QUERY 4 — enumerate the tag keys actually indexed on the measurement, to catch
// an accidental high-cardinality tag early.
schema.measurementTagKeys(bucket: "telemetry_raw", measurement: "tick_latency")
