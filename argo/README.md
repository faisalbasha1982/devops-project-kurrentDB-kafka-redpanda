# `argo/` — progressive delivery (Phase 5)

GitOps + canary delivery for Aequor. Two concerns live here:

```
argo/
  rollouts/                       Argo Rollouts canary for `settlement`
    settlement-rollout.yaml         the Rollout (20% -> 50% -> 100%)
    analysistemplate-consistency.yaml  the drift + latency gate
    README.md                       install / promote / abort / the payoff
  appofapps/
    settlement-rollout-app.yaml     Argo CD Application that syncs rollouts/
```

## The idea

- **Argo CD** (GitOps) keeps the cluster's desired state equal to this repo. The
  app-of-apps `Application` in `appofapps/` continuously syncs `rollouts/`, so the
  canary definition and its gate are themselves version-controlled and
  drift-detected.
- **Argo Rollouts** (progressive delivery) replaces the `settlement` Deployment
  with a `Rollout` that ships new versions as a gated canary, checked against
  Prometheus at every step.

The gate is the point: `aequor_reconciliation_drift == 0` is turned into an
automated deploy verdict. A build that breaks the books aborts before it can
settle a full share of trades. Full walkthrough in
[`rollouts/README.md`](rollouts/README.md).

## Prometheus address

The `AnalysisTemplate` queries `http://prometheus-operated.monitoring.svc.cluster.local:9090`
(the Prometheus Operator's headless service). If you run a plain Prometheus
Deployment, override the `prometheus-address` arg to
`http://prometheus.monitoring.svc:9090`.

## Related

- Fault-injection / DR drills that exercise this gate's underlying signals:
  [`../chaos/`](../chaos/).
- The postmortem of a real gated-abort: [`../docs/POSTMORTEM.md`](../docs/POSTMORTEM.md).
