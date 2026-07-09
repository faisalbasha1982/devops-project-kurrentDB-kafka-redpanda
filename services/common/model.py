"""Aequor shared ledger model.

The single source of truth for how a crypto fill maps to double-entry postings.
Both the settlement service (which writes to TigerBeetle) and the reconciler
(which independently recomputes from the KurrentDB event log) import this, so
they can never drift in their *definition* of correctness — only in execution,
which is exactly what reconciliation is meant to catch.

Phase 1 — ledger correctness:
  * Richer chart of accounts: per-asset customer, venue, **fee** (venue income)
    and **clearing/suspense** (in-flight custody) accounts.
  * Each fill settles as a set of **movements**; the crypto leg passes through the
    clearing/suspense account (custody in-flight), and the customer pays a fee.
  * Each movement is executed as a **two-phase transfer** (PENDING → POSTED) so a
    multi-leg settlement is reserved then confirmed atomically; the whole set is
    LINKED so it commits all-or-nothing.
  * Idempotency/dedup ride on TigerBeetle's `id`: every transfer id is a
    deterministic hash of (trade, movement, phase), so redelivery is a no-op.

Reconciliation only ever compares **posted** balances, and a PENDING→POSTED pair
nets to exactly one posted movement (debit/credit += amount), so the fuller model
leaves `aequor_reconciliation_drift = 0` intact by construction.
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass

# --- Assets -----------------------------------------------------------------
# Each asset is its own TigerBeetle *ledger*. A transfer must have both its
# debit and credit accounts on the same ledger, so a cross-currency trade
# becomes legs on two ledgers (quote + base).
#
# scale = integer minor units per whole unit (TigerBeetle amounts are u128,
# there are no decimals). USD in cents, crypto in 1e8 (satoshi-style).
ASSETS: dict[str, dict] = {
    "USD": {"ledger": 840, "scale": 100, "index": 1},
    "BTC": {"ledger": 1001, "scale": 100_000_000, "index": 2},
    "ETH": {"ledger": 1002, "scale": 100_000_000, "index": 3},
}

# --- Entities (the chart of accounts) ---------------------------------------
# One account per (entity, asset). account_id = entity*10 + asset_index keeps ids
# small, non-zero and collision-free (e.g. customer USD=11, venue BTC=22,
# fee USD=31, clearing BTC=42).
CUSTOMER = 1   # the trading customer
VENUE = 2      # the exchange/venue principal
FEE = 3        # venue fee income (trading commission lands here)
CLEARING = 4   # venue clearing/suspense — crypto in-flight during settlement
ENTITIES = {"customer": CUSTOMER, "venue": VENUE, "fee": FEE, "clearing": CLEARING}

ACCOUNT_CODE = 1000   # generic asset account
TRANSFER_CODE = 720   # "trade settlement"

# Trading commission, in basis points of quote notional (100 bps = 1%). Kept as a
# model constant (NOT a per-service env var) so settlement and reconciler can
# never disagree on it — a mismatch here would show up as reconciliation drift.
FEE_BPS = 10  # 0.10%


def account_id(entity: int, asset: str) -> int:
    """Deterministic small non-zero account id, e.g. customer USD = 11."""
    return entity * 10 + ASSETS[asset]["index"]


def all_accounts() -> list[tuple[int, str]]:
    """(account_id, asset) for every entity x asset combination."""
    out = []
    for asset in ASSETS:
        for entity in (CUSTOMER, VENUE, FEE, CLEARING):
            out.append((account_id(entity, asset), asset))
    return out


def _transfer_id(trade_id: str, tag: str) -> int:
    """Deterministic u128 transfer id from the trade id + a movement/phase tag.

    Deterministic ids are how we get idempotency for free: replaying the same
    fill produces the same transfer ids, and TigerBeetle refuses to create a
    transfer that already exists.
    """
    h = hashlib.sha256(f"{trade_id}:{tag}".encode()).digest()[:16]
    return int.from_bytes(h, "big") | 1   # ensure non-zero


@dataclass(frozen=True)
class Movement:
    """One economic movement of value between two accounts on one ledger.

    Executed as a two-phase transfer: a PENDING transfer (`pending_id`) reserves
    the value, a POST_PENDING transfer (`post_id`) confirms it. The net effect on
    *posted* balances is a single debit/credit of `amount`, which is what the
    reconciler recomputes.
    """
    name: str
    debit_account_id: int
    credit_account_id: int
    amount: int
    ledger: int
    pending_id: int
    post_id: int


@dataclass(frozen=True)
class Postings:
    trade_id: str
    movements: list[Movement]

    def legs(self) -> list[Movement]:
        """Back-compat alias: reconciliation iterates movements as 'legs'."""
        return self.movements


def _mk(trade_id: str, name: str, debit: int, credit: int,
        amount: int, ledger: int) -> Movement:
    return Movement(
        name=name,
        debit_account_id=debit,
        credit_account_id=credit,
        amount=amount,
        ledger=ledger,
        pending_id=_transfer_id(trade_id, f"{name}:pending"),
        post_id=_transfer_id(trade_id, f"{name}:post"),
    )


def compute_fee(quote_amount: int) -> int:
    """Trading commission in quote minor units (integer, deterministic)."""
    return (quote_amount * FEE_BPS) // 10_000


def compute_postings(trade_id: str, symbol: str, side: str,
                     qty: float, price: float) -> Postings:
    """Turn one fill into its double-entry movements.

    Convention (customer trading against the venue):
      buy  -> customer pays quote (+ fee), receives base
      sell -> customer receives quote (- fee), delivers base
    The base (crypto) leg always passes through the venue clearing/suspense
    account, modelling custody-in-flight during settlement. The fee is always
    paid by the customer to the venue fee-income account.
    """
    base_sym, quote_sym = symbol.split("-")
    base = ASSETS[base_sym]
    quote = ASSETS[quote_sym]

    quote_amount = round(qty * price * quote["scale"])
    base_amount = round(qty * base["scale"])
    if quote_amount <= 0 or base_amount <= 0:
        raise ValueError(f"non-positive amount for {trade_id}: {qty}@{price}")
    fee_amount = compute_fee(quote_amount)

    cust_q, venue_q = account_id(CUSTOMER, quote_sym), account_id(VENUE, quote_sym)
    fee_q = account_id(FEE, quote_sym)
    cust_b, venue_b = account_id(CUSTOMER, base_sym), account_id(VENUE, base_sym)
    clear_b = account_id(CLEARING, base_sym)
    ql, bl = quote["ledger"], base["ledger"]

    movements: list[Movement] = []
    if side == "buy":
        # Quote: customer pays the venue; base: venue -> clearing -> customer.
        movements.append(_mk(trade_id, "quote", cust_q, venue_q, quote_amount, ql))
        movements.append(_mk(trade_id, "base_in", venue_b, clear_b, base_amount, bl))
        movements.append(_mk(trade_id, "base_out", clear_b, cust_b, base_amount, bl))
    elif side == "sell":
        # Quote: venue pays the customer; base: customer -> clearing -> venue.
        movements.append(_mk(trade_id, "quote", venue_q, cust_q, quote_amount, ql))
        movements.append(_mk(trade_id, "base_in", cust_b, clear_b, base_amount, bl))
        movements.append(_mk(trade_id, "base_out", clear_b, venue_b, base_amount, bl))
    else:
        raise ValueError(f"unknown side: {side!r}")

    # Fee is always customer -> venue fee income, on the quote ledger.
    if fee_amount > 0:
        movements.append(_mk(trade_id, "fee", cust_q, fee_q, fee_amount, ql))

    return Postings(trade_id=trade_id, movements=movements)
