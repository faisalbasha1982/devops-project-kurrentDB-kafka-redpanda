# Progressive delivery for `settlement` (Argo Rollouts)

This is Phase 5's canary gate. It exists to make one guarantee automatic:

> **A deploy of `settlement` that breaks settlement consistency aborts itself
> before it can corrupt the books.**

The whole Aequor thesis is `event -> ledger -> metric`, verified continuously by
`aequor_reconciliation_drift == 0`. Here that gauge stops being just an alert and
becomes a *deploy verdict*: if a new `settlement` build makes the event log and
the TigerBeetle ledger disagree, Argo Rollouts sees drift go non-zero and rolls
back to the last good version — automatically, in minutes, having touched only a
fraction of the ledger.

## Files

| File | What it is |
|------|------------|
| `settlement-rollout.yaml` | `Rollout` (replaces the settlement `Deployment`). Canary 20% -> 50% -> 100% with pauses. |
| `analysistemplate-consistency.yaml` | `AnalysisTemplate` with the two Prometheus gates: **drift == 0** (hard) and **latency SLO >= 0.99** (soft). |

## How the gate works

Two analyses run against Prometheus (`aequor:settlement_latency_slo:ratio_rate5m`
and `aequor_reconciliation_drift`, both defined/exported today in Phase 3):

1. **Background consistency analysis** — attached at `strategy.canary.analysis`,
   so it runs for the *entire* rollout, at every step and pause. Its
   `reconciliation-drift` metric has `failureLimit: 0`: the first measurement
   where `max(aequor_reconciliation_drift) != 0` fails the run and aborts the
   Rollout. This is the hard gate. Drift is a whole-system signal — the
   reconciler recomputes expected balances from the log and compares to the
   ledger — so it catches a bad settlement build no matter *how* it is wrong
   (wrong amount, wrong account, double-post, a fee-rounding change).

2. **Inline latency analysis** — an `analysis` step after the 20% weight, gating
   on the p99 < 5s SLO recording rule (`ratio_rate5m >= 0.99`). It tolerates one
   bad window (`failureLimit: 1`) so a brief backlog-drain right after a pod swap
   doesn't abort, but a sustained latency regression does.

Because `settlement` is a consumer (no HTTP ingress), the canary "weight" is a
**replica ratio**: at 20% weight, ~1 in 5 settlement pods run the new image and
share the same `settlement` persistent-subscription group, so they settle ~20%
of trades. That is why there's no `trafficRouting:` block — there is no traffic
to split, only work to share.

## Install Argo Rollouts

```bash
# Controller (cluster-scoped) into the argo-rollouts namespace.
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# kubectl plugin (for the get/promote/abort commands below).
curl -sSL -o /usr/local/bin/kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x /usr/local/bin/kubectl-argo-rollouts
```

Apply the manifests (namespace `aequor` assumed to exist from Phase 4):

```bash
kubectl apply -f argo/rollouts/analysistemplate-consistency.yaml -n aequor
kubectl apply -f argo/rollouts/settlement-rollout.yaml
```

> Migrating from a Deployment? A `Rollout` owns its own ReplicaSets. Delete the
> old `settlement` Deployment (or set the Rollout's `workloadRef` to it) so both
> don't manage the same pods. In this repo the Helm chart (Phase 4) renders the
> `Rollout` directly for `settlement`.

## Trigger, watch, promote, abort

A new rollout is triggered by changing the pod template — normally a new image
tag from CI/Argo CD:

```bash
kubectl argo rollouts set image settlement \
  settlement=ghcr.io/aequor/aequor-settlement:<new-sha> -n aequor
```

Watch it live (weights, analysis runs, pause status):

```bash
kubectl argo rollouts get rollout settlement -n aequor --watch
```

Manual controls:

```bash
# Approve the final human pause and go to 100%.
kubectl argo rollouts promote settlement -n aequor

# Skip all remaining steps and jump straight to 100% (use sparingly).
kubectl argo rollouts promote settlement -n aequor --full

# Abort now and scale the canary back to the stable version.
kubectl argo rollouts abort settlement -n aequor

# After fixing a bad image and pushing a new tag, retry from the top.
kubectl argo rollouts retry rollout settlement -n aequor
```

## The payoff (see it fail safe)

Deploy a deliberately broken build — the classic being a fee-rounding change in
`services/common/model.py` (floor vs. round) that makes the fee-income account
disagree with what the reconciler recomputes. Then:

```bash
kubectl argo rollouts get rollout settlement -n aequor --watch
```

Expected sequence:
1. Canary reaches 20%. The broken pods settle ~1/5 of trades with the wrong fee.
2. The reconciler's next cycle sees `aequor_reconciliation_drift > 0`.
3. The background `reconciliation-drift` analysis (`failureLimit: 0`) fails.
4. The Rollout status flips to `Degraded`/`Aborted`; the canary ReplicaSet scales
   to zero and stable holds 100%.
5. The reconciler returns to `drift = 0` once the good build is the only one
   settling. No page for a corrupted ledger — the gate caught it.

The postmortem for exactly this incident is in [`docs/POSTMORTEM.md`](../../docs/POSTMORTEM.md).

See also [`../README.md`](../README.md) for the Argo CD app-of-apps overview.
