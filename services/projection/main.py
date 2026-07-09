"""projection — register KurrentDB projections and export their read models.

Phase 2c: a KurrentDB **Projection** (JavaScript running in the database) builds a
read model — settlement status per symbol — directly from the immutable event
log. This service owns that projection's lifecycle and turns its state into
Prometheus metrics.

What it does each loop:
  1. Register (idempotently) the continuous projections defined by the sibling
     .js files, then enable them. Re-running with a changed query updates it.
  2. Poll get_projection_state() -> the JSON read model -> per-symbol gauges.
  3. Poll get_projection_statistics() -> progress / status / processing lag.

The projection is a *derived* read model: it never writes to TigerBeetle and
never appends events, so it cannot affect settlement idempotency or the
reconciliation invariant (aequor_reconciliation_drift = 0). If it falls behind,
that shows up as projection lag — an SLO signal, not a correctness problem.
"""
import os
import re
import time

from kurrentdbclient import KurrentDBClient
from kurrentdbclient.exceptions import (
    AlreadyExistsError,
    KurrentDBClientError,
    NotFoundError,
)
from prometheus_client import Gauge, start_http_server

HERE = os.path.dirname(os.path.abspath(__file__))
KURRENTDB_URI = os.getenv("KURRENTDB_URI", "kurrentdb://kurrentdb:2113?tls=false")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
INTERVAL = float(os.getenv("PROJECTION_INTERVAL", "5"))
# v2 read-model engine requires KurrentDB >= 26.1; default to the widely
# supported v1 so the stack runs on the pinned `kurrent-latest` image.
ENGINE = os.getenv("PROJECTION_ENGINE", "v1")

# Projections this service owns: (projection name, source .js file).
PROJECTIONS = [
    ("aequor-settlement-status", "settlement_status.js"),
    ("aequor-volume-by-instrument", "volume_by_instrument.js"),
]

# --- settlement-status read model (per symbol) ------------------------------
EXECUTED = Gauge("aequor_projection_symbol_executed",
                 "TradeExecuted events folded into the read model, per symbol",
                 ["symbol"])
SETTLED = Gauge("aequor_projection_symbol_settled",
                "TradeSettled events folded into the read model, per symbol",
                ["symbol"])
UNSETTLED = Gauge("aequor_projection_symbol_unsettled",
                  "executed - settled, per symbol (should trend to 0)", ["symbol"])

# --- per-instrument volume read model ---------------------------------------
VOL_QTY = Gauge("aequor_projection_symbol_volume_qty",
                "Cumulative traded base quantity, per symbol", ["symbol"])
VOL_NOTIONAL = Gauge("aequor_projection_symbol_volume_notional",
                     "Cumulative quote-notional (qty*price), per symbol", ["symbol"])

# --- projection health / lag (per projection) -------------------------------
PROGRESS = Gauge("aequor_projection_progress_percent",
                 "Projection catch-up progress (100 = fully caught up)", ["projection"])
LAG_BYTES = Gauge("aequor_projection_lag_bytes",
                  "Commit-position gap between the log head and the projection",
                  ["projection"])
RUNNING = Gauge("aequor_projection_running",
                "1 if the projection status is Running, else 0", ["projection"])
EVENTS_PROCESSED = Gauge("aequor_projection_events_processed_after_restart",
                         "Events the projection has processed since last restart",
                         ["projection"])
LAST_POLL = Gauge("aequor_projection_last_poll_ts",
                  "Wall-clock of the last successful stats/state poll")

_POS_RE = re.compile(r"(\d{2,})")


def connect_kurrent() -> KurrentDBClient:
    while True:
        try:
            client = KurrentDBClient(uri=KURRENTDB_URI)
            client.get_commit_position()
            print("[projection] connected to KurrentDB", flush=True)
            return client
        except Exception as e:  # noqa: BLE001
            print(f"[projection] KurrentDB not ready ({e}); retrying...", flush=True)
            time.sleep(2)


def load_query(filename: str) -> str:
    with open(os.path.join(HERE, filename), encoding="utf-8") as fh:
        return fh.read()


def ensure_projection(kdb: KurrentDBClient, name: str, query: str) -> None:
    """Register the projection, or update its query if it already exists.

    Idempotent lifecycle management: safe to run on every boot. A changed .js
    query is pushed via update_projection so the read model definition stays in
    lock-step with the source in the repo.
    """
    try:
        kdb.create_projection(name=name, query=query, engine_version=ENGINE)
        print(f"[projection] created '{name}' (engine={ENGINE})", flush=True)
    except AlreadyExistsError:
        try:
            kdb.update_projection(name=name, query=query)
            print(f"[projection] updated existing '{name}'", flush=True)
        except KurrentDBClientError as e:  # noqa: BLE001
            print(f"[projection] update of '{name}' failed ({e}); keeping current",
                  flush=True)
    # A freshly created projection is already running; enabling an already-enabled
    # one is a harmless no-op that also recovers a manually-stopped projection.
    try:
        kdb.enable_projection(name)
    except KurrentDBClientError as e:  # noqa: BLE001
        print(f"[projection] enable '{name}' warning: {e}", flush=True)


def parse_commit_position(position: str) -> int | None:
    """Best-effort extract of a commit position from a stats position string.

    KurrentDB reports a projection's position as an opaque string whose format
    varies by version (e.g. 'C:12345/P:12345' or a JSON-ish tag). We only need
    the commit ('C') offset to compute a byte lag comparable to the settlement
    subscription lag, so pull the first plausible offset out defensively.
    """
    if not position:
        return None
    m = re.search(r"C[:=]?\s*(\d+)", position)
    if m:
        return int(m.group(1))
    m = _POS_RE.search(position)
    return int(m.group(1)) if m else None


def export_settlement_status(state: dict) -> None:
    symbols = (state or {}).get("symbols", {}) or {}
    for symbol, s in symbols.items():
        executed = int(s.get("executed", 0))
        settled = int(s.get("settled", 0))
        EXECUTED.labels(symbol=symbol).set(executed)
        SETTLED.labels(symbol=symbol).set(settled)
        UNSETTLED.labels(symbol=symbol).set(max(0, executed - settled))


def export_volume(state: dict) -> None:
    symbols = (state or {}).get("symbols", {}) or {}
    for symbol, s in symbols.items():
        VOL_QTY.labels(symbol=symbol).set(float(s.get("qty", 0)))
        VOL_NOTIONAL.labels(symbol=symbol).set(float(s.get("notional", 0)))


def poll_health(kdb: KurrentDBClient, name: str, head: int) -> None:
    stats = kdb.get_projection_statistics(name)
    PROGRESS.labels(projection=name).set(float(stats.progress))
    RUNNING.labels(projection=name).set(
        1 if str(stats.status).lower().startswith("running") else 0)
    EVENTS_PROCESSED.labels(projection=name).set(
        int(stats.events_processed_after_restart))
    pos = parse_commit_position(stats.position)
    if pos is not None and head:
        LAG_BYTES.labels(projection=name).set(max(0, head - pos))


def main() -> None:
    start_http_server(METRICS_PORT)
    kdb = connect_kurrent()

    for name, filename in PROJECTIONS:
        ensure_projection(kdb, name, load_query(filename))

    print(f"[projection] exporting read models every {INTERVAL}s", flush=True)
    while True:
        try:
            head = kdb.get_commit_position()
            for name, _ in PROJECTIONS:
                poll_health(kdb, name, head)

            try:
                export_settlement_status(kdb.get_projection_state(
                    "aequor-settlement-status").value)
                export_volume(kdb.get_projection_state(
                    "aequor-volume-by-instrument").value)
            except NotFoundError:
                pass  # state not materialized yet on a cold projection

            LAST_POLL.set(time.time())
        except Exception as e:  # noqa: BLE001
            print(f"[projection] poll error: {e}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
