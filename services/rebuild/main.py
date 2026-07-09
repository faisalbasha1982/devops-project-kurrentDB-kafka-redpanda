"""rebuild — reconstruct a read model from nothing but the event log (Phase 2d).

The disaster-recovery thesis of an event-sourced system: if the immutable log
survives, every derived read model can be rebuilt from it. This one-shot tool
proves it. It does a catch-up read of the whole log (`read_all()`), folds the
same settlement-status read model the in-database projection maintains, and — if
the live projection is present — diffs the two to show they agree.

Use it to:
  * bootstrap a read model into a fresh store after a projection reset/restore,
  * verify the projection hasn't diverged from the log (a consistency check),
  * demonstrate the DR runbook in docs/DR.md.

Run: `docker compose run --rm rebuild`   (or with --json for machine output).

This is a pure reader: it never writes TigerBeetle and never appends events, so
it cannot affect settlement idempotency or the reconciliation invariant.
"""
import argparse
import json
import os
import sys
import time

from kurrentdbclient import KurrentDBClient
from kurrentdbclient.exceptions import NotFoundError

KURRENTDB_URI = os.getenv("KURRENTDB_URI", "kurrentdb://kurrentdb:2113?tls=false")
PROJECTION_NAME = os.getenv("PROJECTION_NAME", "aequor-settlement-status")


def connect_kurrent() -> KurrentDBClient:
    for attempt in range(30):
        try:
            client = KurrentDBClient(uri=KURRENTDB_URI)
            client.get_commit_position()
            return client
        except Exception as e:  # noqa: BLE001
            print(f"[rebuild] KurrentDB not ready ({e}); retrying...", file=sys.stderr)
            time.sleep(2)
    raise SystemExit("[rebuild] could not connect to KurrentDB")


def rebuild_from_log(kdb: KurrentDBClient) -> dict:
    """Fold the whole event log into the settlement-status read model.

    Mirrors services/projection/settlement_status.js exactly, in Python, so the
    rebuild is a faithful re-derivation of the same read model.
    """
    symbols: dict[str, dict] = {}
    pending: dict[str, str] = {}
    events = 0

    def bucket(sym: str) -> dict:
        return symbols.setdefault(sym, {"executed": 0, "settled": 0})

    for event in kdb.read_all():
        if event.type == "TradeExecuted":
            data = json.loads(event.data)
            sym = data.get("symbol")
            tid = data.get("trade_id")
            if not sym or not tid:
                continue
            bucket(sym)["executed"] += 1
            pending[tid] = sym
            events += 1
        elif event.type == "TradeSettled":
            data = json.loads(event.data)
            tid = data.get("trade_id")
            sym = pending.pop(tid, None)
            if sym is None:
                continue
            bucket(sym)["settled"] += 1
            events += 1

    for sym, s in symbols.items():
        s["unsettled"] = max(0, s["executed"] - s["settled"])
    return {"symbols": symbols, "pending_count": len(pending), "events_folded": events}


def live_projection_state(kdb: KurrentDBClient) -> dict | None:
    try:
        value = kdb.get_projection_state(PROJECTION_NAME).value
    except NotFoundError:
        return None
    except Exception as e:  # noqa: BLE001
        print(f"[rebuild] could not read live projection state: {e}", file=sys.stderr)
        return None
    symbols = {}
    for sym, s in (value or {}).get("symbols", {}).items():
        ex, se = int(s.get("executed", 0)), int(s.get("settled", 0))
        symbols[sym] = {"executed": ex, "settled": se, "unsettled": max(0, ex - se)}
    return symbols


def diff(rebuilt: dict, live: dict | None) -> list[str]:
    if live is None:
        return ["live projection not present — skipped comparison"]
    problems = []
    for sym in set(rebuilt) | set(live):
        r = rebuilt.get(sym, {})
        l = live.get(sym, {})
        for k in ("executed", "settled", "unsettled"):
            if r.get(k, 0) != l.get(k, 0):
                problems.append(f"{sym}.{k}: rebuilt={r.get(k, 0)} live={l.get(k, 0)}")
    return problems


def main() -> None:
    ap = argparse.ArgumentParser(description="Rebuild the settlement-status read "
                                             "model from the KurrentDB event log.")
    ap.add_argument("--json", action="store_true", help="emit machine-readable JSON")
    args = ap.parse_args()

    kdb = connect_kurrent()
    rebuilt = rebuild_from_log(kdb)
    live = live_projection_state(kdb)
    problems = diff(rebuilt["symbols"], live)

    if args.json:
        print(json.dumps({"rebuilt": rebuilt, "live": live, "problems": problems},
                         indent=2))
    else:
        print(f"[rebuild] folded {rebuilt['events_folded']} events; "
              f"{rebuilt['pending_count']} still unsettled")
        for sym, s in sorted(rebuilt["symbols"].items()):
            print(f"  {sym:<10} executed={s['executed']:<6} settled={s['settled']:<6} "
                  f"unsettled={s['unsettled']}")
        if live is None:
            print("[rebuild] live projection not present — rebuild stands alone")
        elif not problems:
            print("[rebuild] OK — rebuilt read model matches the live projection")
        else:
            print("[rebuild] MISMATCH vs live projection:")
            for p in problems:
                print(f"    {p}")

    # Non-zero exit only on a genuine divergence, so this is CI/alert-friendly.
    sys.exit(1 if problems and live is not None else 0)


if __name__ == "__main__":
    main()
