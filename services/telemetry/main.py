"""telemetry — high-frequency operational telemetry into InfluxDB (Phase 3).

Prometheus is the SLO/alerting store (pull, low-frequency, aggregate). This is a
deliberately *separate* side-path for high-frequency operational telemetry —
tick-to-trade latency samples per instrument — the kind of high-volume data you
push, keep briefly at full resolution, then downsample. The point is to practice
the three things InfluxDB actually tests you on:

  1. **Flux** — the downsampling task and example queries are Flux, not PromQL.
  2. **Tag-cardinality management** — tags are indexed, so tagging by an unbounded
     dimension (trade_id, order_id, user_id) explodes series cardinality and melts
     the database. Here tags are strictly low-cardinality (symbol, side, venue);
     the identifier and the measured value are FIELDS, which are not indexed.
  3. **Retention + downsampling** — raw points live in a short-retention bucket;
     a Flux task rolls them up into a long-retention bucket.

This service ensures both buckets exist, installs the downsampling task, and then
writes synthetic-but-realistic tick latency at high frequency.
"""
import math
import os
import random
import time

from influxdb_client import BucketRetentionRules, InfluxDBClient, Point
from influxdb_client.client.write_api import SYNCHRONOUS
from prometheus_client import Counter, start_http_server

INFLUX_URL = os.getenv("INFLUX_URL", "http://influxdb:8086")
INFLUX_TOKEN = os.getenv("INFLUX_TOKEN", "aequor-dev-token")
INFLUX_ORG = os.getenv("INFLUX_ORG", "aequor")
RAW_BUCKET = os.getenv("INFLUX_RAW_BUCKET", "telemetry_raw")
DS_BUCKET = os.getenv("INFLUX_DS_BUCKET", "telemetry_downsampled")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
HZ = float(os.getenv("TELEMETRY_HZ", "20"))  # points per second per symbol

SYMBOLS = ["BTC-USD", "ETH-USD"]
SIDES = ["buy", "sell"]

POINTS_WRITTEN = Counter("aequor_telemetry_points_written_total",
                         "High-frequency telemetry points written to InfluxDB")

# Raw at full resolution for 24h; downsampled rollups kept 30d. Cheap to store,
# and the rollup is what dashboards/analytics actually read.
RAW_RETENTION_S = 24 * 3600
DS_RETENTION_S = 30 * 24 * 3600

# Flux downsampling task: every minute, roll raw tick latency up into 1m
# mean/p99 per (symbol, side) and write to the long-retention bucket. This is the
# canonical retention+downsampling pattern, expressed in Flux.
DOWNSAMPLE_FLUX = f'''
from(bucket: "{RAW_BUCKET}")
  |> range(start: -2m)
  |> filter(fn: (r) => r._measurement == "tick_latency" and r._field == "latency_ms")
  |> group(columns: ["symbol", "side"])
  |> aggregateWindow(every: 1m, fn: mean, createEmpty: false)
  |> set(key: "_measurement", value: "tick_latency_1m")
  |> set(key: "_field", value: "latency_ms_mean")
  |> to(bucket: "{DS_BUCKET}", org: "{INFLUX_ORG}")
'''


def connect() -> InfluxDBClient:
    while True:
        try:
            client = InfluxDBClient(url=INFLUX_URL, token=INFLUX_TOKEN, org=INFLUX_ORG)
            if client.ping():
                print("[telemetry] connected to InfluxDB", flush=True)
                return client
        except Exception as e:  # noqa: BLE001
            print(f"[telemetry] InfluxDB not ready ({e}); retrying...", flush=True)
        time.sleep(2)


def ensure_bucket(client: InfluxDBClient, name: str, retention_s: int) -> None:
    buckets = client.buckets_api()
    if buckets.find_bucket_by_name(name) is not None:
        return
    buckets.create_bucket(
        bucket_name=name, org=INFLUX_ORG,
        retention_rules=BucketRetentionRules(type="expire", every_seconds=retention_s))
    print(f"[telemetry] created bucket '{name}' (retention {retention_s}s)", flush=True)


def ensure_downsample_task(client: InfluxDBClient) -> None:
    tasks = client.tasks_api()
    try:
        existing = tasks.find_tasks(name="aequor-downsample-tick-latency")
        if existing:
            return
        tasks.create_task_every(
            name="aequor-downsample-tick-latency",
            flux=DOWNSAMPLE_FLUX, every="1m", organization=INFLUX_ORG)
        print("[telemetry] created downsampling task (1m rollup)", flush=True)
    except Exception as e:  # noqa: BLE001
        # Non-fatal: the task file in observability/influxdb/ can be applied by an
        # operator with `influx task create`. Keep writing raw data regardless.
        print(f"[telemetry] could not auto-create downsample task ({e}); "
              f"apply observability/influxdb/downsample.flux manually", flush=True)


def sample_latency(symbol: str) -> float:
    """A plausible tick-to-trade latency in ms: log-normal-ish with occasional
    spikes, and BTC a touch busier than ETH."""
    base = 3.5 if symbol == "BTC-USD" else 2.8
    jitter = abs(random.gauss(0, 1)) * base
    spike = 40.0 if random.random() < 0.01 else 0.0
    return round(base + jitter + spike, 3)


def main() -> None:
    start_http_server(METRICS_PORT)
    client = connect()
    ensure_bucket(client, RAW_BUCKET, RAW_RETENTION_S)
    ensure_bucket(client, DS_BUCKET, DS_RETENTION_S)
    ensure_downsample_task(client)

    write_api = client.write_api(write_options=SYNCHRONOUS)
    interval = 1.0 / (HZ * len(SYMBOLS)) if HZ > 0 else 0.05
    print(f"[telemetry] emitting ~{HZ}Hz/symbol tick latency to '{RAW_BUCKET}'",
          flush=True)

    while True:
        for symbol in SYMBOLS:
            side = random.choice(SIDES)
            # TAGS: strictly low-cardinality (indexed). FIELDS: the measured value
            # and any high-cardinality identifier (NOT indexed) — this is the
            # cardinality discipline the whole side-path is here to demonstrate.
            point = (Point("tick_latency")
                     .tag("symbol", symbol)
                     .tag("side", side)
                     .tag("venue", "aequor")
                     .field("latency_ms", sample_latency(symbol))
                     .field("seq", int(math.floor(time.time() * 1000)) % 1_000_000))
            try:
                write_api.write(bucket=RAW_BUCKET, record=point)
                POINTS_WRITTEN.inc()
            except Exception as e:  # noqa: BLE001
                print(f"[telemetry] write error: {e}", flush=True)
                time.sleep(1)
            time.sleep(interval)


if __name__ == "__main__":
    main()
