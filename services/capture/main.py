"""capture — Kafka fills -> immutable TradeExecuted events in KurrentDB.

Each fill becomes one event in its own per-trade stream (`trade-<id>`), which
is the source of truth. Capture is idempotent: appending with an expected
version of NO_STREAM means a replayed fill (same trade id) is rejected as
already-captured rather than duplicated.
"""
import json
import os
import time

from confluent_kafka import Consumer
from kurrentdbclient import KurrentDBClient, NewEvent, StreamState
from kurrentdbclient.exceptions import WrongCurrentVersionError

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "redpanda:9092")
TOPIC = os.getenv("TOPIC", "trades.fills")
KURRENTDB_URI = os.getenv("KURRENTDB_URI", "kurrentdb://kurrentdb:2113?tls=false")


def connect_kurrent() -> KurrentDBClient:
    while True:
        try:
            client = KurrentDBClient(uri=KURRENTDB_URI)
            client.get_commit_position()  # forces a connection
            print("[capture] connected to KurrentDB", flush=True)
            return client
        except Exception as e:  # noqa: BLE001 - retry any startup error
            print(f"[capture] KurrentDB not ready ({e}); retrying...", flush=True)
            time.sleep(2)


def main() -> None:
    kdb = connect_kurrent()
    consumer = Consumer({
        "bootstrap.servers": BOOTSTRAP,
        "group.id": "capture",
        "auto.offset.reset": "earliest",
        "enable.auto.commit": True,
    })
    consumer.subscribe([TOPIC])
    print(f"[capture] consuming {TOPIC} from {BOOTSTRAP}", flush=True)

    captured = 0
    while True:
        msg = consumer.poll(1.0)
        if msg is None:
            continue
        if msg.error():
            print(f"[capture] consumer error: {msg.error()}", flush=True)
            continue

        fill = json.loads(msg.value())
        stream = f"trade-{fill['trade_id']}"
        event = NewEvent(type="TradeExecuted", data=msg.value())
        try:
            kdb.append_to_stream(stream, events=event,
                                 current_version=StreamState.NO_STREAM)
            captured += 1
            if captured % 10 == 0:
                print(f"[capture] captured {captured} trades", flush=True)
        except WrongCurrentVersionError:
            # Stream already exists -> this fill was captured before. Idempotent.
            pass


if __name__ == "__main__":
    main()
