# `chaos/` — fault-injection drills (Phase 5)

Two game-day drills that prove Aequor's two independent durability guarantees
(the ones `docs/DR.md` spells out) actually hold under a real node loss:

1. **Kill a TigerBeetle replica** — the ledger (system of record) survives a
   replica loss via VSR and never loses a posted transfer.
2. **Kill a KurrentDB node** — the event log (source of truth) survives a node
   loss via cluster quorum and never loses an event.

The pass criterion for both is the same one that runs in steady state: the
invariant `aequor_reconciliation_drift` returns to (or never leaves) **0**. If
the books re-agree after a node dies, the fault was tolerated.

## Files

| File | What |
|------|------|
| `kill-tigerbeetle-replica.sh` | Kill one TigerBeetle replica. `--k8s` or `--compose`. |
| `kill-kurrentdb-node.sh` | Kill one KurrentDB node. `--k8s` or `--compose`. |
| `podchaos-tigerbeetle.yaml` | Chaos Mesh `PodChaos` — declarative alternative to the TB script. |

Both scripts take `--dry-run` (print the command, do nothing) and require an
explicit mode. They only ever touch **one** node.

## The signals to watch

All exported to Prometheus today (Phase 0-3). Reconciler metrics are on `:8002`
locally / `:8000` in-cluster; settlement on `:8001` / `:8000`.

| Metric | Steady state | During the drill | Meaning |
|--------|--------------|------------------|---------|
| `aequor_reconciliation_drift` | `0` | must return to `0` | log vs. ledger agree — the pass/fail signal |
| `aequor_unsettled_trades` | `0` | may blip up, must drain to `0` | `TradeExecuted` without `TradeSettled` — settlement backlog |
| `aequor_settlement_subscription_lag` | ~`0` | spikes on reconnect, returns near `0` | commit-position gap for the persistent subscription |
| `aequor_projection_lag_bytes` | low | may rise, catches up | read-model freshness (KurrentDB drill) |

One-liner to watch the invariant:

```bash
watch -n2 'curl -s localhost:8002/metrics | grep -E "aequor_reconciliation_drift|aequor_unsettled_trades"'
```

---

## Drill 1 — kill a TigerBeetle replica

**Hypothesis.** A TigerBeetle cluster of `2f+1` replicas tolerates the loss of
`f`. Killing one replica of a 3-node cluster keeps a quorum: settlement keeps
posting transfers, no posted transfer is lost, and drift stays 0. When the
replica rejoins it catches up via state sync.

### Kubernetes (EKS / Phase 4 — real fault tolerance)

```bash
./chaos/kill-tigerbeetle-replica.sh --k8s          # deletes the highest-ordinal pod
# or declaratively:
kubectl apply -f chaos/podchaos-tigerbeetle.yaml
```

**Expected:** `kubectl get pods -l app.kubernetes.io/name=tigerbeetle` shows one
pod recreated. `aequor_reconciliation_drift` never leaves 0. `unsettled_trades`
may briefly rise while the killed replica is out of quorum, then drains.

**Recovery:** the StatefulSet controller recreates the pod automatically; it
rejoins and state-syncs. No manual step. Confirm drift = 0 and `unsettled = 0`.

### Local docker-compose (Phase 0-3 — degraded + recovery only)

The lab runs TigerBeetle as a single node, so there is no quorum to survive a
kill. This variant demonstrates the *degraded then recovered* path instead —
still a valid DR rehearsal:

```bash
./chaos/kill-tigerbeetle-replica.sh --compose      # stop ~20s, then start
```

**Expected:** while TB is down, settlement stalls and `aequor_unsettled_trades`
climbs (fills keep landing in the log, just can't be posted). On restart,
settlement resumes and drains the backlog; **because transfer ids are a
deterministic hash of (trade, movement, phase), the replayed backlog never
double-posts**, so drift returns cleanly to 0.

---

## Drill 2 — kill a KurrentDB node

**Hypothesis.** A 3-node KurrentDB cluster elects a leader via gossip and
tolerates one node loss: capture keeps appending, settlement's persistent
subscription reconnects to a surviving node, no event is lost, drift stays 0.

### Kubernetes (EKS / Phase 4 — real fault tolerance)

```bash
./chaos/kill-kurrentdb-node.sh --k8s               # deletes a follower pod
```

**Expected:** if the killed node was a follower, no visible impact. If it was the
leader, a new leader is elected in seconds; settlement's subscription drops and
reconnects (`aequor_settlement_subscription_lag` spikes then recovers). Confirm a
new leader:

```bash
kubectl -n aequor logs sts/kurrentdb --tail=20 | grep -i -E "leader|elect"
```

`aequor_reconciliation_drift` stays 0 throughout — no event was lost, so nothing
can diverge.

### Local docker-compose (Phase 0-3 — outage + recovery only)

`KURRENTDB_CLUSTER_SIZE=1`, so a kill is a full outage. It still proves the
resilience of the *pipeline around* the log:

```bash
./chaos/kill-kurrentdb-node.sh --compose           # stop ~25s, then start
```

**Expected:** while KurrentDB is down, capture can't append and settlement's
subscription drops — but `feed` keeps producing to Kafka, so **nothing is lost;
fills queue in the `trades.fills` topic**. On restart, capture drains the Kafka
backlog into the log and settlement resumes from its server-side checkpoint (no
full replay). `unsettled_trades` drains and drift returns to 0.

---

## Why these two, specifically

They map one-to-one onto the DR recovery table in `docs/DR.md`:

- *"KurrentDB node (cluster) — VSR/quorum: a follower is promoted"* → Drill 2.
- *"TigerBeetle data file — re-derive by replaying `TradeExecuted` through
  settlement (idempotent transfer ids → no double-post)"* → the recovery half of
  Drill 1.

The whole point of Phase 5's progressive-delivery gate is that the *same*
invariant these drills verify (`drift = 0`) is what the Argo Rollouts
`AnalysisTemplate` gates a deploy on. Chaos proves the invariant is robust to
infra failure; the canary proves it's robust to bad code. See
[`../argo/rollouts/README.md`](../argo/rollouts/README.md) and the postmortem in
[`../docs/POSTMORTEM.md`](../docs/POSTMORTEM.md).
