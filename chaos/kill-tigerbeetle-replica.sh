#!/usr/bin/env bash
# =============================================================================
# chaos drill: kill a TigerBeetle replica
# -----------------------------------------------------------------------------
# Demonstrates TigerBeetle's VSR (Viewstamped Replication) fault tolerance: a
# cluster of 2f+1 replicas tolerates the loss of f. We kill ONE replica and show
# that settlement keeps posting, the cluster keeps a quorum, and the invariant
# `aequor_reconciliation_drift` returns (stays) at 0. When the replica rejoins it
# catches up via state sync.
#
# Two modes:
#   --k8s      delete one TigerBeetle StatefulSet pod (EKS / Phase 4)
#   --compose  stop the local single-node TigerBeetle (Phase 0-3 lab)
#
# NOTE ON THE LOCAL LAB: docker-compose runs TigerBeetle as a SINGLE node
# (--development), so there is NO quorum to survive a kill. --compose therefore
# demonstrates the *degraded* path (settlement stalls, unsettled_trades climbs)
# and RECOVERY (settlement drains the backlog on restart, drift back to 0) —
# still a valid DR drill, just not a fault-tolerance one. Real VSR tolerance
# needs the multi-replica StatefulSet, hence --k8s.
#
# Safe by construction: never touches more than one replica; prints what to
# watch; requires an explicit mode flag; --dry-run shows the command only.
# =============================================================================
set -euo pipefail

MODE=""
NAMESPACE="${NAMESPACE:-aequor}"
STS="${TB_STATEFULSET:-tigerbeetle}"
COMPOSE_SVC="${TB_COMPOSE_SERVICE:-tigerbeetle}"
REPLICA_ORDINAL="${TB_REPLICA_ORDINAL:-}"   # empty -> pick the highest ordinal
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage: kill-tigerbeetle-replica.sh (--k8s | --compose) [--dry-run]

  --k8s       Delete one TigerBeetle StatefulSet pod in the cluster.
  --compose   Stop the local docker-compose TigerBeetle container.
  --dry-run   Print the command that would run, do nothing.

Env overrides:
  NAMESPACE           k8s namespace (default: aequor)
  TB_STATEFULSET      StatefulSet name (default: tigerbeetle)
  TB_REPLICA_ORDINAL  which pod ordinal to kill (default: highest)
  TB_COMPOSE_SERVICE  compose service name (default: tigerbeetle)
EOF
}

log()  { printf '\033[1;36m[chaos]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[chaos]\033[0m %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s)     MODE="k8s" ;;
    --compose) MODE="compose" ;;
    --dry-run) DRY_RUN="true" ;;
    -h|--help) usage; exit 0 ;;
    *) warn "unknown arg: $1"; usage; exit 2 ;;
  esac
  shift
done

if [[ -z "$MODE" ]]; then
  warn "a mode is required (--k8s or --compose)"
  usage
  exit 2
fi

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    log "DRY RUN: $*"
  else
    log "+ $*"
    "$@"
  fi
}

watch_hint() {
  cat <<EOF

Watch the invariant hold (or degrade and recover). In Prometheus:
  aequor_reconciliation_drift            -> must return to / stay 0
  aequor_unsettled_trades                -> may blip up, must drain to 0
  aequor_settlement_subscription_lag     -> may blip up, must return near 0

Quick poll (adjust host: settlement metrics are on :8000/metrics in-cluster,
:8001 on the local lab, reconciler :8002):
  watch -n2 'curl -s localhost:8002/metrics | grep -E "aequor_reconciliation_drift|aequor_unsettled_trades"'
EOF
}

case "$MODE" in
  k8s)
    command -v kubectl >/dev/null || { warn "kubectl not found"; exit 1; }
    if [[ -z "$REPLICA_ORDINAL" ]]; then
      # Highest ordinal = most likely a follower, safest to bounce.
      REPLICAS=$(kubectl -n "$NAMESPACE" get statefulset "$STS" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
      if [[ -z "$REPLICAS" || "$REPLICAS" -lt 1 ]]; then
        warn "could not read replicas for statefulset/$STS in ns/$NAMESPACE"
        exit 1
      fi
      if [[ "$REPLICAS" -lt 3 ]]; then
        warn "statefulset/$STS has $REPLICAS replica(s); VSR needs >=3 to tolerate a loss."
        warn "proceeding — this will demonstrate the DEGRADED path, not fault tolerance."
      fi
      REPLICA_ORDINAL=$((REPLICAS - 1))
    fi
    POD="${STS}-${REPLICA_ORDINAL}"
    log "killing one TigerBeetle replica: pod/${POD} (ns/${NAMESPACE})"
    log "VSR quorum should survive; settlement continues; drift stays 0."
    run kubectl -n "$NAMESPACE" delete pod "$POD" --wait=false
    log "StatefulSet controller will recreate ${POD}; it rejoins via state sync."
    watch_hint
    ;;

  compose)
    if docker compose version >/dev/null 2>&1; then DC=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose)
    else warn "neither 'docker compose' nor 'docker-compose' found"; exit 1; fi
    warn "local TigerBeetle is single-node: this shows DEGRADED + RECOVERY,"
    warn "not quorum survival (see the header comment)."
    log "stopping compose service '${COMPOSE_SVC}' for ~20s, then restarting."
    run "${DC[@]}" stop "$COMPOSE_SVC"
    if [[ "$DRY_RUN" != "true" ]]; then
      log "TigerBeetle down. Watch aequor_unsettled_trades climb (settlement stalls)."
      sleep 20
      run "${DC[@]}" start "$COMPOSE_SVC"
      log "TigerBeetle back. settlement resumes from its persistent-sub checkpoint;"
      log "unsettled_trades drains to 0 and drift returns to 0 (idempotent transfer ids"
      log "mean the replayed backlog never double-posts)."
    fi
    watch_hint
    ;;
esac

log "drill complete."
