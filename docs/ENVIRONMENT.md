# Environment & troubleshooting

Runs on **one WSL2 Ubuntu distro with Docker**, one container per component.
No VMs — single-host containers are the right granularity through Phase 3.
Keep the repo in the Linux filesystem (`~/aequor`), never under `/mnt/c/...`
(bind-mount IO and file-watching across the Windows boundary is slow and flaky).

## WSL2 resources

`C:\Users\<you>\.wslconfig` (then `wsl --shutdown` from PowerShell):

```ini
[wsl2]
memory=8GB
processors=4
swap=2GB
```

Real footprint with all services: ~5 GB RAM. 8 GB laptop → give WSL 5–6 GB;
each service has `mem_limit: 256m`.

## Host kernel prerequisites (both required, learned the hard way)

**TigerBeetle needs io_uring.** Docker's default seccomp profile blocks the
io_uring syscalls (symptom: `error: PermissionDenied` / `io_uring is not
available` at format time). Fixes already applied in-repo:
- `make init`'s format step passes `--security-opt seccomp=unconfined`.
- the `tigerbeetle` compose service carries `security_opt: [seccomp:unconfined]`.
- The `kernel.io_uring_disabled` sysctl the error suggests only exists on Linux
  6.6+. On older WSL2 kernels the seccomp override is the actual fix. In
  production you'd instead ship a custom seccomp profile allowing exactly
  `io_uring_setup`/`io_uring_enter`/`io_uring_register` for the ledger pods.

**Redpanda needs enough async I/O contexts.** Symptom: redpanda container flips
to `unhealthy`/crashes on start. Fix on the WSL2 host:
```bash
echo 'fs.aio-max-nr=1048576' | sudo tee /etc/sysctl.d/99-redpanda.conf
sudo sysctl --system
```

## Other gotchas already fixed in-repo

- Redpanda has **no** `--advertise-schema-registry-addr` flag (rpk rejects it).
  Schema registry listens on 8081 internal / 18081 host and is reached over plain
  HTTP; it doesn't advertise like the Kafka protocol.
- Prometheus mounts the **directory** `./observability/prometheus` (not the single
  file). A missing single-file bind source gets auto-created by Docker as a
  directory and crashes the mount; a directory source fails safe.
- TigerBeetle image is distroless — REPL is
  `docker exec -it aequor-tigerbeetle /tigerbeetle repl --cluster=0 --addresses=3000`.

## Ports

| Port  | Service                    |
|-------|----------------------------|
| 2113  | KurrentDB UI + gRPC        |
| 3000  | TigerBeetle gRPC           |
| 8080  | Redpanda Console           |
| 19092 | Redpanda Kafka (external)  |
| 18081 | Redpanda Schema Registry   |
| 9644  | Redpanda admin / metrics   |
| 9090  | Prometheus                 |
| 3001  | Grafana (→ container 3000) |
| 8001  | settlement /metrics        |
| 8002  | reconciler /metrics        |

## Key metrics

- `aequor_reconciliation_drift` — event-log balances vs ledger. **Must be 0.**
- `aequor_unsettled_trades` — TradeExecuted minus TradeSettled (settlement lag).
- `aequor_settlement_subscription_lag` — commit-position gap to the log head.
- `aequor_settlements_total` / `_skipped_total` / `_nacked_total`.
