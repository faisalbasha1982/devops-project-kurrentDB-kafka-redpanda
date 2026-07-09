"""settlement — Phase 2: durable, resumable, lifecycle-aware settlement.

Changes from Phase 0c:
  * consumes via a PERSISTENT SUBSCRIPTION (server-side checkpointing + ack/nack)
    instead of a catch-up subscription, so a restart resumes from the server
    checkpoint rather than re-reading the whole log.
  * emits a TradeSettled event back into the trade's stream, giving each trade a
    real aggregate lifecycle: trade-<id> = [TradeExecuted, TradeSettled].
  * exports subscription lag (commit-position gap to the log head) as an SLO metric.

Idempotency is unchanged in spirit: transfer ids are deterministic, and the
TradeSettled append is gated on the stream version, so redelivery is safe.
"""
import json
import os
import time

import tigerbeetle as tb
from kurrentdbclient import KurrentDBClient, NewEvent
from kurrentdbclient.exceptions import AlreadyExistsError, WrongCurrentVersionError
from prometheus_client import Counter, Gauge, start_http_server

from common.model import (ACCOUNT_CODE, TRANSFER_CODE, ASSETS, all_accounts,
                          account_id, compute_postings)

KURRENTDB_URI = os.getenv("KURRENTDB_URI", "kurrentdb://kurrentdb:2113?tls=false")
TB_CLUSTER = int(os.getenv("TB_CLUSTER", "0"))
TB_ADDRESSES = os.getenv("TB_ADDRESSES", "tigerbeetle:3000")
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))
GROUP = os.getenv("SUBSCRIPTION_GROUP", "settlement")

FILLS_SEEN = Counter("aequor_fills_seen_total", "TradeExecuted events observed")
SETTLED = Counter("aequor_settlements_total", "Trades settled to the ledger")
SKIPPED = Counter("aequor_settlements_skipped_total", "Already-settled trades skipped")
NACKED = Counter("aequor_settlements_nacked_total", "Events nacked for retry")
LAST_TS = Gauge("aequor_settlement_last_event_ts", "Wall-clock of last processed event")
SUB_LAG = Gauge("aequor_settlement_subscription_lag",
                "Commit-position gap between the log head and the last acked event")

OK = {"CREATED", "EXISTS"}


def connect_tb() -> tb.ClientSync:
    while True:
        try:
            client = tb.ClientSync(cluster_id=TB_CLUSTER, replica_addresses=TB_ADDRESSES)
            client.lookup_accounts([account_id(1, "USD")])
            print("[settlement] connected to TigerBeetle", flush=True)
            return client
        except Exception as e:  # noqa: BLE001
            print(f"[settlement] TigerBeetle not ready ({e}); retrying...", flush=True)
            time.sleep(2)


def connect_kurrent() -> KurrentDBClient:
    while True:
        try:
            client = KurrentDBClient(uri=KURRENTDB_URI)
            client.get_commit_position()
            print("[settlement] connected to KurrentDB", flush=True)
            return client
        except Exception as e:  # noqa: BLE001
            print(f"[settlement] KurrentDB not ready ({e}); retrying...", flush=True)
            time.sleep(2)


def ensure_accounts(client: tb.ClientSync) -> None:
    accounts = [
        tb.Account(id=acct_id, ledger=ASSETS[asset]["ledger"], code=ACCOUNT_CODE,
                   flags=tb.AccountFlags.HISTORY)
        for acct_id, asset in all_accounts()
    ]
    for r in client.create_accounts(accounts):
        if r.status.name not in OK:
            print(f"[settlement] account create issue: {r.status.name}", flush=True)
    print(f"[settlement] ensured {len(accounts)} accounts", flush=True)


def ensure_subscription(kdb: KurrentDBClient) -> None:
    try:
        kdb.create_subscription_to_all(GROUP, filter_include=["TradeExecuted"],
                                       from_end=False)
        print(f"[settlement] created persistent subscription '{GROUP}'", flush=True)
    except AlreadyExistsError:
        print(f"[settlement] persistent subscription '{GROUP}' already exists", flush=True)


def record_settled(kdb: KurrentDBClient, trade_id: str, movements: int) -> None:
    """Append TradeSettled to the trade stream, idempotent on stream version."""
    event = NewEvent(type="TradeSettled", data=json.dumps({
        "trade_id": trade_id,
        "movements": movements,
        "settled_ts": time.time(),
    }).encode())
    try:
        # Expect the stream to currently hold exactly TradeExecuted (position 0).
        kdb.append_to_stream(f"trade-{trade_id}", events=event, current_version=0)
    except WrongCurrentVersionError:
        pass  # TradeSettled already recorded -> idempotent


def build_transfers(postings) -> list[tb.Transfer]:
    """Two-phase transfers for every movement, LINKED into one atomic chain.

    Each movement becomes a PENDING transfer (reserve) immediately followed by a
    POST_PENDING transfer (confirm). The whole chain is LINKED so it commits
    all-or-nothing; only the final transfer clears LINKED to terminate the chain.
    Because the chain is atomic, the presence of the first pending id implies the
    entire settlement committed — which is what makes idempotency safe.
    """
    transfers: list[tb.Transfer] = []
    for m in postings.movements:
        transfers.append(tb.Transfer(
            id=m.pending_id, debit_account_id=m.debit_account_id,
            credit_account_id=m.credit_account_id, amount=m.amount,
            ledger=m.ledger, code=TRANSFER_CODE,
            flags=tb.TransferFlags.PENDING | tb.TransferFlags.LINKED))
        transfers.append(tb.Transfer(
            id=m.post_id, pending_id=m.pending_id,
            debit_account_id=m.debit_account_id,
            credit_account_id=m.credit_account_id, amount=m.amount,
            ledger=m.ledger, code=TRANSFER_CODE,
            flags=tb.TransferFlags.POST_PENDING_TRANSFER | tb.TransferFlags.LINKED))
    # Terminate the linked chain: the last transfer must not be LINKED.
    last = transfers[-1]
    last.flags = last.flags & ~tb.TransferFlags.LINKED
    return transfers


def settle(tbc: tb.ClientSync, kdb: KurrentDBClient, fill: dict) -> None:
    postings = compute_postings(
        fill["trade_id"], fill["symbol"], fill["side"],
        float(fill["qty"]), float(fill["price"]),
    )
    first_pending = postings.movements[0].pending_id

    if tbc.lookup_transfers([first_pending]):
        SKIPPED.inc()  # chain already committed atomically -> idempotent skip
    else:
        transfers = build_transfers(postings)
        hard = [r for r in tbc.create_transfers(transfers) if r.status.name not in OK]
        if hard:
            raise RuntimeError(f"transfer errors {[r.status.name for r in hard]}")
        SETTLED.inc()

    record_settled(kdb, postings.trade_id, len(postings.movements))


def main() -> None:
    start_http_server(METRICS_PORT)
    tbc = connect_tb()
    ensure_accounts(tbc)
    kdb = connect_kurrent()
    ensure_subscription(kdb)

    print(f"[settlement] reading persistent subscription '{GROUP}'", flush=True)
    subscription = kdb.read_subscription_to_all(GROUP)
    for event in subscription:
        if event.type != "TradeExecuted":
            subscription.ack(event)
            continue
        FILLS_SEEN.inc()
        LAST_TS.set(time.time())
        try:
            settle(tbc, kdb, json.loads(event.data))
            subscription.ack(event)
            head = kdb.get_commit_position()
            SUB_LAG.set(max(0, head - (event.commit_position or 0)))
        except Exception as e:  # noqa: BLE001
            print(f"[settlement] processing error, nacking for retry: {e}", flush=True)
            NACKED.inc()
            subscription.nack(event, action="retry")


if __name__ == "__main__":
    main()
