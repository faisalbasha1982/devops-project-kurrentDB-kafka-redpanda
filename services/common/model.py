"""Aequor shared ledger model.

The single source of truth for how a crypto fill maps to double-entry postings.
Both the settlement service (which writes to TigerBeetle) and the reconciler
(which independently recomputes from the KurrentDB event log) import this, so
they can never drift in their *definition* of correctness — only in execution,
which is exactly what reconciliation is meant to catch.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass

# --- Assets -----------------------------------------------------------------
# Each asset is its own TigerBeetle *ledger*. A transfer must have both its
# debit and credit accounts on the same ledger, so a cross-currency trade
# becomes two legs (a quote leg and a base leg), one per ledger.
#
# scale = integer minor units per whole unit (TigerBeetle amounts are u128,
# there are no decimals). USD in cents, crypto in 1e8 (satoshi-style).
ASSETS: dict[str, dict] = {
    "USD": {"ledger": 840, "scale": 100, "index": 1},
    "BTC": {"ledger": 1001, "scale": 100_000_000, "index": 2},
    "ETH": {"ledger": 1002, "scale": 100_000_000, "index": 3},
}

# --- Entities ---------------------------------------------------------------
CUSTOMER = 1
VENUE = 2
ENTITIES = {"customer": CUSTOMER, "venue": VENUE}

ACCOUNT_CODE = 1000   # generic asset account
TRANSFER_CODE = 720   # "trade settlement"


def account_id(entity: int, asset: str) -> int:
    """Deterministic small non-zero account id, e.g. customer USD = 11."""
    return entity * 10 + ASSETS[asset]["index"]


def all_accounts() -> list[tuple[int, str]]:
    """(account_id, asset) for every entity x asset combination."""
    out = []
    for asset in ASSETS:
        for entity in (CUSTOMER, VENUE):
            out.append((account_id(entity, asset), asset))
    return out


def _transfer_id(trade_id: str, leg: str) -> int:
    """Deterministic u128 transfer id from the trade id + leg name.

    Deterministic ids are how we get idempotency for free: replaying the same
    fill produces the same two transfer ids, and TigerBeetle refuses to create
    a transfer that already exists.
    """
    h = hashlib.sha256(f"{trade_id}:{leg}".encode()).digest()[:16]
    return int.from_bytes(h, "big") | 1   # ensure non-zero


@dataclass(frozen=True)
class Leg:
    id: int
    debit_account_id: int
    credit_account_id: int
    amount: int
    ledger: int


@dataclass(frozen=True)
class Postings:
    trade_id: str
    quote: Leg
    base: Leg

    def legs(self) -> list[Leg]:
        return [self.quote, self.base]


def compute_postings(trade_id: str, symbol: str, side: str,
                     qty: float, price: float) -> Postings:
    """Turn one fill into its two double-entry legs.

    Convention (customer trading against the venue):
      buy  -> customer pays quote, receives base
      sell -> customer receives quote, pays base
    """
    base_sym, quote_sym = symbol.split("-")
    base = ASSETS[base_sym]
    quote = ASSETS[quote_sym]

    quote_amount = round(qty * price * quote["scale"])
    base_amount = round(qty * base["scale"])
    if quote_amount <= 0 or base_amount <= 0:
        raise ValueError(f"non-positive amount for {trade_id}: {qty}@{price}")

    cust_q, venue_q = account_id(CUSTOMER, quote_sym), account_id(VENUE, quote_sym)
    cust_b, venue_b = account_id(CUSTOMER, base_sym), account_id(VENUE, base_sym)

    if side == "buy":
        # quote leg: customer -> venue ; base leg: venue -> customer
        quote_leg = Leg(_transfer_id(trade_id, "quote"), cust_q, venue_q,
                        quote_amount, quote["ledger"])
        base_leg = Leg(_transfer_id(trade_id, "base"), venue_b, cust_b,
                       base_amount, base["ledger"])
    elif side == "sell":
        quote_leg = Leg(_transfer_id(trade_id, "quote"), venue_q, cust_q,
                        quote_amount, quote["ledger"])
        base_leg = Leg(_transfer_id(trade_id, "base"), cust_b, venue_b,
                       base_amount, base["ledger"])
    else:
        raise ValueError(f"unknown side: {side!r}")

    return Postings(trade_id=trade_id, quote=quote_leg, base=base_leg)
