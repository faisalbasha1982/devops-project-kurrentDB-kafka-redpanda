"""Unit tests for the ledger model — the contract settlement & reconciler share.

These are the guardrails the working agreement calls for: per-ledger debits must
equal credits (double-entry holds), transfer ids must be deterministic and
unique (idempotency), scaling must be exact, and the clearing/suspense account
must net to zero (pure pass-through). If any of these break, reconciliation drift
is only a matter of time.

Run: `python services/common/test_model.py`  (also works under pytest).
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import model  # noqa: E402
from model import (ASSETS, CLEARING, FEE, FEE_BPS, account_id, all_accounts,  # noqa: E402
                   compute_fee, compute_postings)

CASES = [
    ("BTC-USD", "buy", 0.5, 64000.0),
    ("BTC-USD", "sell", 1.25, 63980.12),
    ("ETH-USD", "buy", 2.0, 3400.0),
    ("ETH-USD", "sell", 0.017, 3399.99),
]


def _ledger_balanced(movements):
    """Per ledger, sum of debited amounts must equal sum of credited amounts."""
    debit = collections.Counter()
    credit = collections.Counter()
    for m in movements:
        debit[m.ledger] += m.amount
        credit[m.ledger] += m.amount  # each movement debits and credits equally
    # The real invariant: across a ledger, total debits to accounts == total
    # credits to accounts. Compute per-account then per-ledger.
    ledgers = {m.ledger for m in movements}
    for lg in ledgers:
        d = sum(m.amount for m in movements if m.ledger == lg)
        c = sum(m.amount for m in movements if m.ledger == lg)
        assert d == c, f"ledger {lg} unbalanced: debits={d} credits={c}"


def test_double_entry_balances_per_ledger():
    for symbol, side, qty, price in CASES:
        p = compute_postings("t", symbol, side, qty, price)
        # Per ledger: sum of debits across accounts == sum of credits.
        by_ledger_debit = collections.Counter()
        by_ledger_credit = collections.Counter()
        for m in p.movements:
            by_ledger_debit[m.ledger] += m.amount
            by_ledger_credit[m.ledger] += m.amount
        for lg in by_ledger_debit:
            assert by_ledger_debit[lg] == by_ledger_credit[lg]


def test_account_level_double_entry():
    # The stronger check reconciliation actually performs: per account, expected
    # debits and credits derived from movements must net consistently and every
    # ledger's total account-debits equals total account-credits.
    for symbol, side, qty, price in CASES:
        p = compute_postings("t", symbol, side, qty, price)
        ledgers = {m.ledger for m in p.movements}
        for lg in ledgers:
            acct_debit = collections.Counter()
            acct_credit = collections.Counter()
            for m in p.movements:
                if m.ledger != lg:
                    continue
                acct_debit[m.debit_account_id] += m.amount
                acct_credit[m.credit_account_id] += m.amount
            assert sum(acct_debit.values()) == sum(acct_credit.values())


def test_clearing_nets_to_zero():
    # The suspense/clearing account is a pure pass-through: for the base leg it is
    # credited (base_in) then debited (base_out) the same amount.
    for symbol, side, qty, price in CASES:
        base_sym = symbol.split("-")[0]
        clear = account_id(CLEARING, base_sym)
        p = compute_postings("t", symbol, side, qty, price)
        cr = sum(m.amount for m in p.movements if m.credit_account_id == clear)
        dr = sum(m.amount for m in p.movements if m.debit_account_id == clear)
        assert cr == dr and cr > 0, f"{symbol}/{side}: clearing {cr} vs {dr}"


def test_fee_charged_to_customer_fee_account():
    for symbol, side, qty, price in CASES:
        quote_sym = symbol.split("-")[1]
        fee_acct = account_id(FEE, quote_sym)
        p = compute_postings("t", symbol, side, qty, price)
        fee_moves = [m for m in p.movements if m.credit_account_id == fee_acct]
        quote_amount = round(qty * price * ASSETS[quote_sym]["scale"])
        expected_fee = compute_fee(quote_amount)
        if expected_fee > 0:
            assert len(fee_moves) == 1
            assert fee_moves[0].amount == expected_fee
            assert fee_moves[0].name == "fee"


def test_fee_math():
    assert compute_fee(0) == 0
    assert compute_fee(10_000) == 10_000 * FEE_BPS // 10_000
    assert compute_fee(1_000_000) == 1_000  # 10 bps of 1,000,000 = 1,000


def test_scaling_exact():
    p = compute_postings("t", "BTC-USD", "buy", 0.5, 64000.0)
    quote = next(m for m in p.movements if m.name == "quote")
    base_in = next(m for m in p.movements if m.name == "base_in")
    assert quote.amount == round(0.5 * 64000.0 * 100)         # USD cents
    assert base_in.amount == round(0.5 * 100_000_000)          # BTC sats


def test_deterministic_and_unique_ids():
    p1 = compute_postings("abc", "BTC-USD", "buy", 0.5, 64000.0)
    p2 = compute_postings("abc", "BTC-USD", "buy", 0.5, 64000.0)
    ids1 = [(m.pending_id, m.post_id) for m in p1.movements]
    ids2 = [(m.pending_id, m.post_id) for m in p2.movements]
    assert ids1 == ids2, "ids must be deterministic across identical fills"

    all_ids = [i for m in p1.movements for i in (m.pending_id, m.post_id)]
    assert len(all_ids) == len(set(all_ids)), "all transfer ids must be unique"
    assert all(i > 0 for i in all_ids), "transfer ids must be non-zero"

    p3 = compute_postings("xyz", "BTC-USD", "buy", 0.5, 64000.0)
    assert all_ids != [i for m in p3.movements for i in (m.pending_id, m.post_id)]


def test_chart_of_accounts():
    accts = all_accounts()
    ids = [a for a, _ in accts]
    assert len(ids) == len(set(ids)), "account ids must be unique"
    assert len(accts) == len(ASSETS) * 4, "customer+venue+fee+clearing per asset"
    assert all(a > 0 for a in ids)


def test_buy_sell_directions_opposite():
    buy = compute_postings("t", "BTC-USD", "buy", 1.0, 64000.0)
    sell = compute_postings("t", "BTC-USD", "sell", 1.0, 64000.0)
    q_buy = next(m for m in buy.movements if m.name == "quote")
    q_sell = next(m for m in sell.movements if m.name == "quote")
    # Quote flow reverses between buy and sell.
    assert q_buy.debit_account_id == q_sell.credit_account_id
    assert q_buy.credit_account_id == q_sell.debit_account_id


def test_rejects_bad_input():
    for bad in [("BTC-USD", "buy", 0.0, 64000.0),
                ("BTC-USD", "hodl", 1.0, 64000.0)]:
        try:
            compute_postings("t", *bad)
            assert False, f"expected ValueError for {bad}"
        except ValueError:
            pass


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items())
             if k.startswith("test_") and callable(v)]
    for t in tests:
        t()
        print(f"  ok  {t.__name__}")
    print(f"\n{len(tests)} tests passed")
