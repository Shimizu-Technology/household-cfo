# VERA event-driven queue experiment (round 2)

This draft is an experimental implementation, **not ready for runtime activation**. The adapter deliberately refuses non-test environments. No production queue configuration, schedule, migration or hosting setting changes. Round 1 (#322) is untouched.

## Context and acceptance

Base: `fa9946f5` (origin/main, 2026-11-20). VERA serves household-finance participants, coaches and administrators. Imports, reminders, enterprise admission and recovery depend on durable background jobs. Sources: README, `api/config/{queue,recurring,database}.yml`, `EnterpriseSyncJob`, installed Solid Queue 1.4.0. Brain Dump is unavailable on this host; no production state was inspected.

Agent-executed affected-flow acceptance uses the round-1 harness, synthetic jobs and a synthetic authenticated workspace in one disposable local database. Required: idle SQL/min; immediate p95 <= approximately 260 ms; scheduled lateness; 30-job burst; retry; persisted unclaimed work after restart; first authenticated request after 60 seconds idle. Additional candidate checks: listener disconnect/reconnect, bulk enqueue, rollback without notification/execution. Browser, physical devices, provider delivery and actual Neon suspend/resume are not covered by these backend measurements.

## Design

`QueueWakeup::Poller` prepends the installed worker and dispatcher pollers only when the benchmark explicitly enables it. Two statement-level PostgreSQL triggers notify after ready inserts and scheduled inserts/updates, including bulk enqueue and concurrency release. Notifications are transaction-bound hints. Solid Queue retains SKIP LOCKED claims, retries, scheduled dispatch, semaphore expiry, process liveness and recurring-execution deduplication.

Each poller opens a dedicated PG session **after fork and before its first claim**, then waits on its notification socket and Solid Queue's existing self-pipe. Notifications arriving between claiming and sleeping remain socket-readable. The self-pipe retains shutdown and pool-completion wakeups. Dispatchers inspect the earliest durable scheduled timestamp and sleep until it is due. Idle polls use a 60-second recovery sweep. A disconnected listener reconnects before claiming; connection failure falls back to the original 100 ms worker / 1 s dispatcher polling. A live but silently broken notification path can delay work up to 60 seconds: a material readiness blocker until independently tested and operationally monitored. Multiple listeners can wake together and contend for claims.

The experiment adds one direct session per worker process and dispatcher, outside the existing AR pool (default 8). Pool capacity and database connection limits must account for these. A PgBouncer transaction-pooled URL cannot be used for LISTEN. `database.yml` uses `QUEUE_DATABASE_URL || DATABASE_URL` for production queue writes; it contains no verified endpoint or direct-listener URL. The repo alone cannot establish the deployed topology. Notification triggers must be installed on the **same database as the queue**, including separate queue databases and schema-load restores; the current SQL file is installed only by the guarded benchmark. Rails' Ruby schema dumps do not preserve these triggers. Shipping this as a production migration without a verified install/restore path would be unsafe.

## Safe reproduction

Run sequentially with no concurrent task-owned suites. The database name is fixed deliberately. No `.env` or provider credentials are needed.

```sh
cd api
export RAILS_ENV=test PARALLEL_WORKERS=1
export DATABASE_URL=postgresql://agent@localhost:5432/vera_wakeup_bench_20261120
export DATABASE_TEST_NAME=vera_wakeup_bench_20261120
# Before EVERY db: command, validate both the URL and resolved database.yml.
ruby -ruri -rerb -ryaml -e 'u=URI(ENV.fetch("DATABASE_URL")); c=YAML.safe_load(ERB.new(File.read("config/database.yml")).result, aliases: true).fetch("test"); abort "Unsafe DB" unless u.host == "localhost" && u.port == 5432 && u.path == "/vera_wakeup_bench_20261120" && c["database"] == u.path[1..]'
bin/rails db:prepare
ruby script/benchmark_queue_polling.rb 0.1 > ../docs/performance/queue-wakeup-before.json
QUEUE_WAKEUP_BENCH=1 QUEUE_LISTEN_DATABASE_URL="$DATABASE_URL" ruby script/benchmark_queue_polling.rb 0.1 > ../docs/performance/queue-wakeup-after.json
ruby script/benchmark_queue_sources.rb > ../docs/performance/queue-wakeup-sources.json
```

Both benchmark entrypoints also validate the resolved Rails database before fixture writes. They reject the shared development database. PG LISTEN setup is outside the measured idle window and is not captured by Active Record SQL instrumentation; each listener executes one LISTEN at startup/reconnect and no timed SQL keepalive. Actual notifications and trigger work during enqueue are not counted as separate client SQL statements. Queries, transactions and raw timing samples are retained in JSON. These are local statement counts, not compute-hours or billing measurements.

## Remaining wake sources and decision

Heartbeats stay at 60 seconds and dead-process pruning at 5 minutes. Disabling them compromises crash detection and recovery. Dispatcher concurrency maintenance stays at the gem's interval (600 seconds); it releases expired semaphores and blocked work. Static recurring schedules use timers rather than continuous database polling, but each due occurrence creates durable queue/deduplication rows. Recovery jobs run every 5 minutes; daily retention/Plaid jobs and hourly finished-job cleanup also remain.

EnterpriseSyncJob is scheduled every 30 seconds even when WORKOS_SYNC_ENABLED is false; its disabled body returns without business SQL, but recurring enqueue/claim/completion still writes queue rows. When enabled it polls WorkOS and reconciles admissions; changing its cadence could delay admission and is outside the evidence here. A future safe reduction can omit this recurring entry when the feature is disabled, with explicit configuration tests. This draft leaves it unchanged. Source probes measure its enqueue and disabled body separately; enabled business work depends on tenant/provider state and is not measured locally.

Even a successful worker experiment cannot enable Neon sleep while these timers remain. Keep compute ready under Leon's condition: this test keeps PostgreSQL running and cannot establish cold-start latency. Do not apply this prototype to Håfa Recipes, Cornerstone Payroll, AIRE or Marianas yet. First resolve production connection/trigger lifecycle and outage/concurrency acceptance in VERA, then benchmark each app independently against its own latency and recovery needs.

## Safety limits before promotion

Keep the original 100 ms production worker interval; do not adopt round 1's slower 500 ms value. The prototype is opt-in through a local benchmark and rejects production. It is not a completed autosuspend implementation.

Before activation, require an independently reviewed trigger migration and schema-restore path; prove the direct listener and queue writer reach the same database; verify transaction-pool isolation and connection budgets; test separate worker OS processes, rolling restarts, notification blackholes, reconnect backoff and a sustained backlog. A timed-out direct connection currently adds up to two seconds before a fallback claim; fallback pickup was tested only against an immediately refused local connection. This is another reason the healthy-path p95 alone cannot support deployment. The benchmark's restart scenario covers unclaimed durable work, not a killed in-flight job or supervisor recovery. Concurrency release is exercised with five jobs sharing one semaphore, not every expiry/orphan path.

The nested worktree at `household-cfo-b/.worktrees/vera-event-wakeup` isolates the task after another session switched the supplied checkout's branch. Only the isolated reruns are retained as final evidence. Both final runs use the same disposable database with notification triggers installed; baseline leaves notifications unconsumed and retains the original polling behavior. The baseline therefore includes the small trigger enqueue cost. No shared database or other session's branch/resources was changed.

## Isolated results

| Metric | Original 100 ms poll | Event-driven prototype |
|---|---:|---:|
| Idle SQL/min | 1422.0 | 16.0 |
| Pickup p50 (ms) | 98.6 | 4.4 |
| Pickup p95 (ms) | 238.8 | 10.6 |
| Pickup max (ms) | 252.2 | 16.0 |
| Scheduled lateness (ms) | 253.7 | 101.8 |
| 30-job burst (ms) | 243.1 | 85.1 |
| Retry completion (ms) | 1767.0 | 1083.4 |
| Restart pickup (ms) | 3.9 | 6.5 |
| First authenticated request after idle (ms) | 56.1 | 51.5 |

Single 60-second windows and 30 immediate-job samples; not a production percentile guarantee. All seven required backend scenarios passed locally. Five concurrency-limited jobs passed in each run. Candidate-only reconnect, refused-listener fallback, bulk enqueue (30) and rollback checks passed.

## Remaining-source measurements

Raw SQL: `queue-wakeup-sources.json`; worker/dispatcher probes are in both timing JSON files. Heartbeat: 4 statements/process/60 s; concurrency maintenance: 2 statements/600 s when empty. The 16-statement candidate idle window contains 8 heartbeat statements and 8 recovery-sweep statements. It excludes production scheduler/supervisor processes and recurring enqueue/execution; the total application idle rate will therefore be higher.

| Probe (single invocation) | Statements |
|---|---:|
| supervisor_prune_no_dead_processes | 1 |
| scheduler_heartbeat | 4 |
| enterprise_disabled_business_body | 0 |
| enterprise_recurring_enqueue | 8 |
| recurring_enqueue_synchronize_enterprise_admission | 8 |
| recurring_enqueue_recover_document_extraction | 8 |
| recurring_enqueue_recover_challenge_reminders | 8 |
| recurring_enqueue_expire_challenge_source_leases | 8 |
| recurring_enqueue_recover_document_source_cleanup | 8 |
| recurring_enqueue_clear_solid_queue_finished_jobs | 8 |
| recurring_enqueue_recover_stale_plaid_items | 8 |
| recurring_enqueue_recover_stale_content_source_url_intakes | 8 |
| recurring_enqueue_redact_terminal_content_source_url_intakes | 8 |

The enterprise enqueue probe is per occurrence, so twice that count per minute precedes claiming and completion. Production recurring entries were enqueued without workers: recovery/provider bodies did not run. These counts measure queue plumbing, not data-dependent business workloads. The scheduler has no dynamic polling by default; its heartbeat adds 4 statements/minute, and a supervised topology adds the supervisor heartbeat plus the measured prune query every 5 minutes. Recovery enqueue costs recur every five minutes even when there is no business work. This accounts for the configured periodic sources without claiming unmeasured business bodies are free.

## Gate and review record

Test environment: Mac mini M4, PostgreSQL 16, Ruby 3.3.7, Rails test mode. Other sessions were active on the host; latency comparisons are single local samples under uncontrolled host load. No production sleep/wake or physical-device result is inferred.

CodeRabbit attempted automatic review of `39d78d3b` on draft PR #344 but reported its free OSS review quota exhausted (33-minute reset estimate at inspection). No review was completed; no independent approval is claimed. Branch protection requires rails_security, rails_lint, rails_test and web, with no required approving-review count. This PR remains draft because of its documented production-safety blockers regardless of CI status.

The initial full Rails run used the benchmark database name and hit the scorecard's mandatory `_test` naming guard. That invalid invocation was stopped by its exact owned PID. The complete suite is rerun on dedicated `vera_wakeup_test_20261120`; no test guard was weakened. Benchmarks remain on `vera_wakeup_bench_20261120`.

Other completed local gates: RuboCop, Brakeman (no warnings), updated gem advisory audit, Zeitwerk, scorecard baseline ratchet, frontend lint, 228 unit-test files / 2,125 tests, frontend build, production dependency audit and repository dependency policy audit. Synthetic-document checks passed 13 tests after installing the repository's pinned dependencies in a disposable Python environment. Existing frontend chunk-size and unused audit-exception warnings remain. Chromium/browser and WebKit were not run locally for this backend-only experiment; WebKit cannot start on this host. No whole-app UI acceptance is claimed.

Host guidance tooling note: `dev-lifecycle` is absent from PATH, so the synced helper was used by absolute path. The shared-context read-only check could not run because `/Users/agent/.config/shimizu-technology/agent-context.json` is missing. Applicable synced skill files were read directly; host configuration was not modified.

Final full Rails gate (2026-11-20–21): **5,576 tests / 83,034 assertions, 1 failure, 0 errors/skips**, 1,382 seconds. `MiaPersonaSetupProposalGuardTest#test_round_five_one_deadline_covers_every_candidate_and_salvage_retry` measured 0.199100 seconds against `< 0.15`. An isolated rerun also failed: 0.216475 seconds (1 test / 2 assertions). This is the same timing assertion recorded in round 1; neither this test nor its implementation changed here, and the queue adapter is not activated by the suite. No unrelated timing threshold was relaxed. The full local gate is **failed**, not clean. All queue benchmark acceptance checks passed separately; that does not override the Rails gate.

Resource disposition: task benchmark/test processes exited; both dedicated localhost databases were dropped after validating their exact identities. Task-owned node_modules, frontend build output and Python scratch environment/caches were removed. Shared PostgreSQL and other sessions' resources remain borrowed and untouched. No browser/server was started. The clean source worktree and draft branch are intentionally retained for the lead; no running-resource handoff is needed.
