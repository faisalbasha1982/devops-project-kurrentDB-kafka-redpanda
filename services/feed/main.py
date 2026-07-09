"""feed — synthetic fill generator -> Kafka topic `trades.fills`."""
import json
import os
import random
import time
import uuid

from confluent_kafka import Producer

BOOTSTRAP = os.getenv("KAFKA_BOOTSTRAP", "redpanda:9092")
TOPIC = os.getenv("TOPIC", "trades.fills")
INTERVAL = float(os.getenv("FEED_INTERVAL", "2"))

MARKETS = {
    "BTC-USD": 64000.0,
    "ETH-USD": 3400.0,
}


def make_fill() -> dict:
    symbol = random.choice(list(MARKETS))
    ref = MARKETS[symbol]
    price = round(ref * random.uniform(0.98, 1.02), 2)
    qty = round(random.uniform(0.01, 1.5), 4)
    side = random.choice(["buy", "sell"])
    return {
        "trade_id": uuid.uuid4().hex,
        "symbol": symbol,
        "side": side,
        "qty": qty,
        "price": price,
        "ts": time.time(),
    }


def main() -> None:
    producer = Producer({"bootstrap.servers": BOOTSTRAP})
    print(f"[feed] producing to {BOOTSTRAP}/{TOPIC} every {INTERVAL}s", flush=True)
    n = 0
    while True:
        fill = make_fill()
        producer.produce(TOPIC, key=fill["symbol"], value=json.dumps(fill))
        producer.poll(0)
        n += 1
        if n % 10 == 0:
            producer.flush(5)
            print(f"[feed] produced {n} fills (last {fill['side']} "
                  f"{fill['qty']} {fill['symbol']} @ {fill['price']})", flush=True)
        time.sleep(INTERVAL)


if __name__ == "__main__":
    main()
