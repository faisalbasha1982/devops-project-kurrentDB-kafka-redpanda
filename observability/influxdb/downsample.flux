// Aequor — tick-latency downsampling task (Phase 3).
//
// Rolls raw high-frequency tick_latency points up into 1-minute means per
// (symbol, side) and writes them to the long-retention bucket. This is the
// retention+downsampling pattern: keep raw data cheap and short-lived, keep the
// rollup small and long-lived.
//
// The `telemetry` service installs this automatically on startup; this file is
// the source of truth and can be applied by hand with:
//   influx task create --org aequor --file observability/influxdb/downsample.flux
//
// Note: the `every` here is 1m. `range(start: -2m)` gives a small overlap so a
// late point isn't missed between runs (dedup on write keeps it idempotent).

option task = {name: "aequor-downsample-tick-latency", every: 1m}

from(bucket: "telemetry_raw")
    |> range(start: -2m)
    |> filter(fn: (r) => r._measurement == "tick_latency" and r._field == "latency_ms")
    |> group(columns: ["symbol", "side"])
    |> aggregateWindow(every: 1m, fn: mean, createEmpty: false)
    |> set(key: "_measurement", value: "tick_latency_1m")
    |> set(key: "_field", value: "latency_ms_mean")
    |> to(bucket: "telemetry_downsampled", org: "aequor")
