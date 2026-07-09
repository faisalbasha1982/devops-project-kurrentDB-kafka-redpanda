# Postmortem — settlement canary fee-rounding regression, auto-aborted on drift

**Status:** Resolved · **Severity:** SEV-3 (contained by the canary gate; no
customer or ledger impact) · **Date:** 2026-07-08 · **Author:** Operational
Excellence Engineer (on-call) · **Review:** blameless, held 2026-07-09

---

## Summary

A routine deploy of the `settlement` service via Argo Rollouts introduced a
change to the shared ledger model (`services/common/model.py`) that switched fee
computation from integer floor division to `round()`. Only `settlement` was
rolled; the `reconciler` continued to run the stable image. For the ~90 seconds
the canary held 20% of traffic, the two components disagreed on the fee for a
minority of trades, `aequor_reconciliation_drift` went non-zero, and the Argo
Rollouts `AnalysisTemplate` (`reconciliation-drift`, `failureLimit: 0`)
**automatically aborted the rollout** and scaled the canary to zero. Drift
returned to 0 within one reconciler cycle. No settled trade was left in a wrong
state on the stable version; there was no customer impact.

This is the Phase 5 design working exactly as intended: a build that would have
corrupted the books aborted itself after touching ~20% of trades for ~90s,
before it could go fleet-wide.

## Impact

- **Customer impact:** none. No customer balance was wrong. The affected legs
  were settled by canary pods only, and the discrepancy was in the *venue
  fee-income* account (internal), off by at most 1 cent per affected trade.
- **Ledger impact:** none persisted. The reconciler flagged drift while the
  canary was live; on abort, only stable (floor-fee) settlement remained and the
  next reconcile showed `drift = 0`. TigerBeetle transfers are immutable, but the
  affected transfers were a bounded, identified set on the canary cohort and net
  to a consistent state under the reverted (stable) model.
- **Blast radius:** ~20% of trades over a ~90s window (canary weight × window).
  Roughly 40–60 trades, of which only those whose `quote_amount * 10 bps` had a
  non-zero fractional cent (about half) actually diverged.
- **SLO impact:** consistency error budget — a brief breach of the hard
  `drift = 0` invariant, caught and reverted automatically. Settlement latency
  SLO (`aequor:settlement_latency_slo:ratio_rate5m`) was unaffected (stayed
  > 0.99). No page fired to a human for a corrupted ledger.

## Timeline (UTC)

| Time | Event |
|------|-------|
| `13:58` | CI merges PR "tidy up fee math in model.py" (floor `//` → `round()`), builds image `aequor-settlement:9f3c1a2`. |
| `14:02` | Argo CD syncs the new image into the `settlement` Rollout. Rollout begins; canary set to `setWeight: 20`. |
| `14:02` | Background `settlement-consistency` analysis starts (runs for the whole rollout). Canary pods begin settling ~20% of trades with `round()`-based fees. |
| `14:03` | `reconciler` (still on stable, floor fees) runs its 10s cycle; expected fee-income balance no longer matches the ledger. `aequor_reconciliation_drift` = 3 (cents). |
| `14:03` | `AnalysisTemplate` metric `reconciliation-drift` measures `max(aequor_reconciliation_drift) = 3`, fails `successCondition` (`== 0`). With `failureLimit: 0` the analysis run is marked **Failed**. |
| `14:03` | Argo Rollouts aborts the rollout; canary ReplicaSet scales toward 0, stable holds 100%. Rollout status → `Degraded`. |
| `14:04` | Only stable settlement pods remain. Next reconciler cycle: `aequor_reconciliation_drift` = 0. `aequor_unsettled_trades` back to 0. |
| `14:05` | On-call acknowledges the `RolloutAborted` notification; confirms `drift = 0` and reads `kubectl argo rollouts get rollout settlement`. |
| `14:20` | Root cause identified from the diff: shared-model change shipped to settlement only. |
| `14:35` | PR reverted; `services/common/test_model.py` reproduces the fee delta offline. Incident closed. |

## Root cause

`services/common/model.py` is a **shared contract** consumed by *both*
`settlement` (which posts fees to TigerBeetle) and `reconciler` (which recomputes
the expected fee-income balance from the log). The changed line:

```python
# before (stable):  floor division, deterministic, matches reconciler
return (quote_amount * FEE_BPS) // 10_000
# after (canary):   banker's rounding — a different value for fractional cents
return round(quote_amount * FEE_BPS / 10_000)
```

For a `quote_amount` where `quote_amount * 10 bps` has a non-zero fractional
cent, `round()` yields a fee 1 cent different from `//`. Progressive delivery
rolled the new model to `settlement` but **not** to `reconciler` (they are
separate Deployments). During the canary window the two components computed the
fee differently, so the reconciler's log-derived expectation for the venue
fee-income account diverged from what the canary settled — exactly what
`aequor_reconciliation_drift` exists to detect.

The trigger was a code change; the *contributing condition* was that a semantic
change to the shared ledger model can be shipped to one consumer at a time, and
any such skew is by definition a drift.

## Detection

- **Automated, no human in the loop for detection.** The Argo Rollouts
  background `settlement-consistency` `AnalysisTemplate` queries Prometheus every
  30s; `max(aequor_reconciliation_drift) == 0` with `failureLimit: 0` is the hard
  gate. It fired on the first non-zero reading, ~60–90s into the canary.
- The `ReconciliationDrift` Prometheus alert (`slo.yml`, `for: 1m`) would also
  have paged, but the canary gate aborted faster than the alert's `for` window —
  the deploy was reverted before it became a human-facing page.
- Time to detect: ~90s. Time to auto-mitigate (abort): ~seconds after detection.

## What went well

- **The gate did its whole job.** The single most important gauge in the system
  turned a book-corrupting deploy into a self-reverting non-event. This is the
  Phase 5 payoff, demonstrated on a real regression.
- Blast radius was bounded to the canary cohort by design (20% weight, no traffic
  routing needed — replica-ratio canary on a consumer).
- Recovery was automatic; on-call's role was to confirm, not to firefight.
- The offline `test_model.py` reproduced the exact fee delta, making root cause
  fast and unambiguous.

## What went poorly

- **The shared-model contract has no cross-service version guard.** Nothing
  prevented shipping a model change to `settlement` without `reconciler`. Drift
  caught the *effect*, but we'd prefer to catch the *cause* before deploy.
- The PR title ("tidy up fee math") undersold a **semantics change to a live
  financial ledger**. Review didn't flag it as touching the consistency contract.
- No unit test asserted floor-vs-round fee behavior, so the change passed CI green.
- The reconciler and settlement image tags are not asserted to be built from the
  same `model.py` version at deploy time.

## Action items

Each item has an owner-role and a tracking checkbox.

- [ ] **Add a `MODEL_VERSION` constant to `services/common/model.py`** and export
  it as a Prometheus gauge label from both settlement and reconciler; add a
  recording rule + alert that fires when the two disagree. *(Owner: Platform
  Engineer)*
- [ ] **Unit-test fee rounding explicitly** in `services/common/test_model.py`:
  assert `compute_fee` uses floor division and pin exact expected values for
  fractional-cent inputs, so any change to the rule fails CI. *(Owner: Settlement
  service owner)*
- [ ] **Gate the canary AnalysisTemplate on model-version skew too** — add a
  metric that fails if settlement and reconciler report different `MODEL_VERSION`
  during a rollout. *(Owner: Operational Excellence Engineer)*
- [ ] **PR checklist / CODEOWNERS on `services/common/model.py`** requiring a
  "ledger contract change" label and a second reviewer for any diff to the shared
  model. *(Owner: Eng lead)*
- [ ] **Document the model-change deploy procedure**: shared-model changes must
  roll settlement and reconciler together (or behind a feature flag with a
  migration), never one canary at a time. Add to `docs/DR.md` runbook set.
  *(Owner: Operational Excellence Engineer)*
- [ ] **Shorten the reconciler cycle during rollouts** (10s → 5s) or add a
  rollout-scoped scrape so the gate reacts even faster. *(Owner: Observability
  owner)*

## Lessons

1. **The invariant is the safety net, and it held.** `aequor_reconciliation_drift`
   isn't a dashboard number — it's a control that stops bad code at 20% blast
   radius. Designing the canary to abort on it paid for itself the first time a
   real regression shipped.
2. **A shared contract deployed piecemeal is itself a fault mode.** When two
   services must agree on a computation, "roll one at a time" is a source of
   divergence. Version the contract and gate on version skew, don't just detect
   the downstream drift.
3. **"Tidy-up" changes to financial math are never cosmetic.** Floor vs. round on
   a fee is a real semantic change to a ledger; it deserves a test and a
   contract-change review, not a green CI and a one-line PR.
4. **Fast, automated mitigation beats fast paging.** The best incident is the one
   that reverts before a human is needed. The gate aborting inside the alert's
   `for: 1m` window is the target we want to keep.
