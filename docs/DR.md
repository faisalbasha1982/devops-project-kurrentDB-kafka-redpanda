# Disaster recovery — KurrentDB & read models (Phase 2d)

The event log is the source of truth. Everything downstream (TigerBeetle
balances, projections, read models) is derivable from it. DR therefore has two
independent guarantees:

1. **The log survives** — via backups + archiving of KurrentDB.
2. **Anything derived can be rebuilt from the log** — proven by the `rebuild` tool.

If both hold, a lost projection, a corrupted read model, or a wiped TigerBeetle
file is a *recoverable* event, not data loss.

---

## 1. Rebuild a read model from the log (the fast path)

The settlement-status read model is a pure fold of the log. To reconstruct it
from nothing — after a projection reset, a restore, or just to check the live
projection hasn't diverged:

```bash
docker compose run --rm rebuild          # human-readable
docker compose run --rm rebuild --json   # machine-readable (CI/alerts)
```

It catch-up-reads the whole log (`read_all()`), folds the same read model the
in-database projection maintains, and **diffs the two**. Matching output proves
the projection is faithful to the log; a mismatch exits non-zero and names the
diverging `symbol.field`. This is both the DR restore step and a standing
consistency check.

Reset the in-database projection and watch it (and `rebuild`) reconverge:

```bash
# via the Admin UI: Projections -> aequor-settlement-status -> Reset
# or with the client:
python -c "from kurrentdbclient import KurrentDBClient as C; \
  C(uri='kurrentdb://localhost:2113?tls=false').reset_projection('aequor-settlement-status')"
```

The `projection` service re-enables it on its next loop; progress climbs back to
100% and `aequor_projection_lag_bytes` falls to 0.

---

## 2. Back up KurrentDB

KurrentDB uses a **simple physical file copy** for backup of a single node — the
chunk files plus index and checkpoints. The safe, supported ordering:

```bash
# 1. Copy the immutable chunk files first (they never change once written).
docker run --rm \
  -v aequor_kurrentdb-data:/data:ro \
  -v "$(pwd)/backups/kurrentdb:/backup" \
  alpine sh -c 'cp -a /data/*.chk /backup/ 2>/dev/null; \
                cp -a /data/chunk-*.* /backup/ 2>/dev/null; \
                cp -a /data/index /backup/index'
```

Rules that keep the copy consistent:

- **Copy `*.chk` (checkpoints) LAST is wrong — copy them AFTER the chunks but the
  `chaser.chk`/`truncate.chk` must reflect data already copied.** Practically:
  copy chunks and index, then the checkpoint files, then verify the writer
  checkpoint points within the copied chunks.
- Never copy while a scavenge (compaction) is running.
- For a *cluster* (Phase 5), back up a **follower** node, or use a filesystem
  snapshot, to avoid perturbing the leader.

Restore:

```bash
docker compose down
docker run --rm -v aequor_kurrentdb-data:/data \
  -v "$(pwd)/backups/kurrentdb:/backup:ro" \
  alpine sh -c 'rm -rf /data/* && cp -a /backup/* /data/'
docker compose up -d kurrentdb
```

Then run `docker compose run --rm rebuild` to confirm the restored log reproduces
the expected read model.

---

## 3. Archiving & retention

Two different retention horizons, deliberately kept separate:

| Data                     | Store        | Retention                              |
|--------------------------|--------------|----------------------------------------|
| Trade event log (truth)  | KurrentDB    | **indefinite** — never scavenge trade streams |
| Derived read models      | projections  | disposable — rebuildable from the log  |
| Operational timeseries   | Prometheus   | 15d (`--storage.tsdb.retention.time`)  |

- **Trade streams (`trade-<id>`) carry `$maxAge`/`$maxCount` = none.** They are
  the audit record; they must not be truncated. (KurrentDB scavenge only reclaims
  space from streams that *have* a retention policy or deleted events.)
- **Cold archiving:** periodically copy sealed chunk files off-box to object
  storage (S3/GCS). Because chunks are immutable once sealed, an incremental
  `aws s3 sync backups/kurrentdb s3://…/kurrentdb/` is safe and cheap. This is the
  seam Phase 4 formalizes (IRSA-scoped bucket, lifecycle to Glacier).
- **Prometheus** downsampling/retention and the InfluxDB retention+downsampling
  policies are Phase 3.

---

## 4. What can and cannot be recovered

| Lost component            | Recovery                                              |
|---------------------------|-------------------------------------------------------|
| A projection / read model | `rebuild` from the log (§1) — full recovery           |
| TigerBeetle data file     | Re-derive by replaying `TradeExecuted` through settlement (idempotent transfer ids → no double-post); `reconciler` confirms `drift = 0` |
| KurrentDB node (cluster)  | VSR: a follower is promoted; re-add a replaced node (Phase 5 chaos drill) |
| KurrentDB (single node)   | Restore from backup (§2), then `rebuild` to verify    |
| The log itself, unbacked  | **Unrecoverable** — hence §2/§3 are the load-bearing controls |

The single invariant that tells you recovery succeeded is the same one that runs
continuously in steady state: `aequor_reconciliation_drift = 0`.
