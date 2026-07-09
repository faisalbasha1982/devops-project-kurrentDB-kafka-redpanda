"""reconciler — the invariant guard.

Every cycle it replays the KurrentDB event log, recomputes what every
TigerBeetle account's posted debits/credits *should* be, and compares that to
what the ledger actually holds. The difference is `aequor_reconciliation_drift`
— it must always be 0. That single gauge is what the Phase 5 canary gate keys
on: a deploy that breaks settlement consistency makes drift spike, and the
rollout auto-aborts before the books are corrupted.
"""
import collections
import json
import os
import time

import tigerbeetle as tb
from kurrentdbclient import KurrentDBClient
from prometheus_client import Gauge, start_http_server

from common.model import all_accounts, account_id, compute_postings

KURRENTDB_URI = os.getenv("KURRENTDB_URI", "kurrentdb://kurrentdb:2113?tls=false")
TB_CLUSTER = int(os.getenv("TB_CLUSTER", "0"))
TB_ADDRESSES = os.getenv("TB_ADDRESSES", "tigerbeetle:3000")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
INTERVAL = float(os.getenv("RECON_INTERVAL", "10"))

DRIFT = Gauge("aequor_reconciliation_drift",
              "Absolute difference between event-derived and ledger balances (must be 0)")
TRADES = Gauge("aequor_reconciliation_trades_counted",
               "Distinct trades seen in the event log this cycle")
UNSETTLED = Gauge("aequor_unsettled_trades",
                  "Trades with a TradeExecuted but no TradeSettled yet (settlement lag)")
LAST_RUN = Gauge("aequor_reconciliation_last_run_ts", "Wall-clock of last reconcile")


def connect_tb() -> tb.ClientSync:
    while True:
        try:
            c = tb.ClientSync(cluster_id=TB_CLUSTER, replica_addresses=TB_ADDRESSES)
            c.lookup_accounts([account_id(1, "USD")])
            print("[reconciler] connected to TigerBeetle", flush=True)
            return c
        except Exception as e:  # noqa: BLE001
            print(f"[reconciler] TigerBeetle not ready ({e}); retrying...", flush=True)
            time.sleep(2)


def connect_kurrent() -> KurrentDBClient:
    while True:
        try:
            c = KurrentDBClient(uri=KURRENTDB_URI)
            c.get_commit_position()
            print("[reconciler] connected to KurrentDB", flush=True)
            return c
        except Exception as e:  # noqa: BLE001
            print(f"[reconciler] KurrentDB not ready ({e}); retrying...", flush=True)
            time.sleep(2)


def expected_from_log(kdb: KurrentDBClient):
    """Replay the event log -> expected posted debits/credits per account.

    Also counts settled events so we can report settlement lag (executed minus
    settled) as a side output.
    """
    exp_debit = collections.Counter()
    exp_credit = collections.Counter()
    trades = 0
    settled = 0
    for event in kdb.read_all():
        if event.type == "TradeSettled":
            settled += 1
            continue
        if event.type != "TradeExecuted":
            continue
        fill = json.loads(event.data)
        try:
            postings = compute_postings(
                fill["trade_id"], fill["symbol"], fill["side"],
                float(fill["qty"]), float(fill["price"]),
            )
        except Exception:  # noqa: BLE001 - skip malformed
            continue
        trades += 1
        for leg in postings.legs():
            exp_debit[leg.debit_account_id] += leg.amount
            exp_credit[leg.credit_account_id] += leg.amount
    return exp_debit, exp_credit, trades, settled


def actual_from_ledger(tbc: tb.ClientSync):
    ids = [acct_id for acct_id, _ in all_accounts()]
    accounts = tbc.lookup_accounts(ids)
    debit = {a.id: a.debits_posted for a in accounts}
    credit = {a.id: a.credits_posted for a in accounts}
    return debit, credit


def reconcile(kdb: KurrentDBClient, tbc: tb.ClientSync) -> None:
    exp_debit, exp_credit, trades, settled = expected_from_log(kdb)
    act_debit, act_credit = actual_from_ledger(tbc)

    ids = {i for i, _ in all_accounts()}
    drift = 0
    for i in ids:
        drift += abs(exp_debit.get(i, 0) - act_debit.get(i, 0))
        drift += abs(exp_credit.get(i, 0) - act_credit.get(i, 0))

    DRIFT.set(drift)
    TRADES.set(trades)
    UNSETTLED.set(max(0, trades - settled))
    LAST_RUN.set(time.time())
    status = "OK" if drift == 0 else "DRIFT!"
    print(f"[reconciler] trades={trades} settled={settled} "
          f"unsettled={max(0, trades - settled)} drift={drift} [{status}]", flush=True)


def main() -> None:
    start_http_server(METRICS_PORT)
    tbc = connect_tb()
    kdb = connect_kurrent()
    print(f"[reconciler] reconciling every {INTERVAL}s", flush=True)
    while True:
        try:
            reconcile(kdb, tbc)
        except Exception as e:  # noqa: BLE001
            print(f"[reconciler] cycle error: {e}", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
