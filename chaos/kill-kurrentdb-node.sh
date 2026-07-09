#!/usr/bin/env bash
# =============================================================================
# chaos drill: kill a KurrentDB node
# -----------------------------------------------------------------------------
# KurrentDB (formerly EventStoreDB) clusters with a gossip/quorum protocol: a
# 3-node cluster elects a leader and tolerates the loss of one node — a follower
# is already caught up, and if the leader dies a new one is elected in seconds.
# We kill ONE node and show that capture keeps appending, settlement's persistent
# subscription reconnects, and `aequor_reconciliation_drift` stays / returns to 0.
#
# Two modes:
#   --k8s      delete one KurrentDB StatefulSet pod (EKS / Phase 4, 3-node cluster)
#   --compose  stop the local single-node KurrentDB (Phase 0-3 lab)
#
# NOTE ON THE LOCAL LAB: docker-compose runs KURRENTDB_CLUSTER_SIZE=1, so there
# is NO quorum to survive a kill. --compose therefore demonstrates the *outage +
# recovery* path (capture/settlement reconnect, subscription resumes from its
# server-side checkpoint, no events lost, drift back to 0). Real cluster
# tolerance needs the 3-node StatefulSet, hence --k8s.
#
# Safe by construction: one node only; explicit mode flag required; --dry-run
# prints the command without running it.
# =============================================================================
set -euo pipefail

MODE=""
NAMESPACE="${NAMESPACE:-aequor}"
STS="${KDB_STATEFULSET:-kurrentdb}"
COMPOSE_SVC="${KDB_COMPOSE_SERVICE:-kurrentdb}"
NODE_ORDINAL="${KDB_NODE_ORDINAL:-}"   # empty -> pick the highest ordinal (a follower)
DRY_RUN="false"

usage() {
  cat <<'EOF'
Usage: kill-kurrentdb-node.sh (--k8s | --compose) [--dry-run]

  --k8s       Delete one KurrentDB StatefulSet pod in the cluster.
  --compose   Stop the local docker-compose KurrentDB container.
  --dry-run   Print the command that would run, do nothing.

Env overrides:
  NAMESPACE           k8s namespace (default: aequor)
  KDB_STATEFULSET     StatefulSet name (default: kurrentdb)
  KDB_NODE_ORDINAL    which pod ordinal to kill (default: highest)
  KDB_COMPOSE_SERVICE compose service name (default: kurrentdb)
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

Watch the log stay the source of truth. In Prometheus:
  aequor_reconciliation_drift            -> must stay / return to 0 (no lost events)
  aequor_unsettled_trades                -> may blip up during failover, drains to 0
  aequor_settlement_subscription_lag     -> spikes on reconnect, returns near 0
  aequor_projection_lag_bytes            -> may rise briefly, projection catches up

Quick poll (reconciler metrics on :8002 locally, :8000 in-cluster):
  watch -n2 'curl -s localhost:8002/metrics | grep -E "aequor_reconciliation_drift|aequor_unsettled_trades"'

In a real cluster, confirm a new leader was elected:
  kubectl -n ${NAMESPACE} logs sts/${STS} --tail=20 | grep -i -E "leader|elect"
EOF
}

case "$MODE" in
  k8s)
    command -v kubectl >/dev/null || { warn "kubectl not found"; exit 1; }
    if [[ -z "$NODE_ORDINAL" ]]; then
      REPLICAS=$(kubectl -n "$NAMESPACE" get statefulset "$STS" \
        -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
      if [[ -z "$REPLICAS" || "$REPLICAS" -lt 1 ]]; then
        warn "could not read replicas for statefulset/$STS in ns/$NAMESPACE"
        exit 1
      fi
      if [[ "$REPLICAS" -lt 3 ]]; then
        warn "statefulset/$STS has $REPLICAS replica(s); a KurrentDB cluster needs >=3"
        warn "to keep quorum through a node loss. Proceeding — expect an OUTAGE, not"
        warn "seamless failover."
      fi
      NODE_ORDINAL=$((REPLICAS - 1))
    fi
    POD="${STS}-${NODE_ORDINAL}"
    log "killing one KurrentDB node: pod/${POD} (ns/${NAMESPACE})"
    log "cluster keeps quorum; a follower or a freshly-elected leader serves reads/writes."
    run kubectl -n "$NAMESPACE" delete pod "$POD" --wait=false
    log "StatefulSet recreates ${POD}; it rejoins the cluster and catches up via gossip/replication."
    watch_hint
    ;;

  compose)
    if docker compose version >/dev/null 2>&1; then DC=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose)
    else warn "neither 'docker compose' nor 'docker-compose' found"; exit 1; fi
    warn "local KurrentDB is single-node (CLUSTER_SIZE=1): this shows OUTAGE + RECOVERY,"
    warn "not quorum survival (see the header comment)."
    log "stopping compose service '${COMPOSE_SVC}' for ~25s, then restarting."
    run "${DC[@]}" stop "$COMPOSE_SVC"
    if [[ "$DRY_RUN" != "true" ]]; then
      log "KurrentDB down. capture can't append; settlement's subscription drops."
      log "feed keeps producing to Kafka — nothing is lost, it queues in the topic."
      sleep 25
      run "${DC[@]}" start "$COMPOSE_SVC"
      log "KurrentDB back. capture drains the Kafka backlog into the log; settlement"
      log "resumes from its persistent-subscription checkpoint (no full replay);"
      log "unsettled_trades drains and drift returns to 0."
    fi
    watch_hint
    ;;
esac

log "drill complete."
