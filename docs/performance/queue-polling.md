# VERA queue polling measurement

## Scope and acceptance

Baseline: `d9849f9f`, November 19, 2026. VERA serves household-finance participants and coaches. Document extraction, reminders, enterprise admission synchronization and recovery use durable background work. Sources: root README, `api/config/recurring.yml`, `api/config/queue.yml`, and installed Solid Queue 1.4.0 source.

This draft reduces recurring queue queries while keeping foreground requests independent of queue polling. It does **not** enable Neon autosuspend. Worker polling moves from 100 to 500 ms using Solid Queue's supported configuration. Dispatcher polling remains 1 second; concurrency, thread count, retries, heartbeats and recurring schedules remain unchanged. The queue's pool completion callback wakes workers as busy threads finish, so a backlog need not wait 500 ms between batches.

Agent-executed affected-flow acceptance: measure idle SQL volume; immediate and scheduled pickup; authenticated workspace after idle; a 30-job burst; retry after a synthetic transient failure; persisted work after worker restart. These use synthetic jobs and a test identity, with no provider calls. Production provider delivery, physical devices and browser journeys are outside this backend-only change's local evidence. Full frontend/browser CI remains a separate gate.

## Reproduce safely

Use a dedicated local database, never `api_development`. The benchmark rejects other URLs and verifies Rails' resolved database before writing fixtures. No `.env` files or production credentials are needed.

```sh
cd api
export RAILS_ENV=test
export DATABASE_URL=postgresql://agent@localhost:5432/vera_polling_bench_20261119
export DATABASE_TEST_NAME=vera_polling_bench_20261119
ruby -ruri -e 'u=URI(ENV.fetch("DATABASE_URL")); abort "Unsafe DB" unless u.host == "localhost" && u.path == "/vera_polling_bench_20261119"'
bin/rails db:prepare
ruby script/benchmark_queue_polling.rb 0.1 > before.json
ruby script/benchmark_queue_polling.rb > after.json
```

Run these sequentially without other task-owned tests/builds. Both runs use the same application code and database; the argument selects the baseline interval, while the second run reads `queue.yml`. The guard must immediately precede every additional `db:` command.

The script boots actual Solid Queue worker/dispatcher threads with production queue selection and concurrency, warms the authenticated workspace once, then counts uncached SQL statements (including transactions, excluding schema discovery) over 60 seconds. This is a local query-volume proxy, not measured compute hours or billing savings. Heartbeats and concurrency maintenance are included when they fall in the window. Production scheduler/supervisor and recurring business queries are excluded, so production totals will be higher. Thirty sequential arrivals sample varying poll phases. Scheduled latency is measured from the job's due time. Burst timing includes enqueue through completion of all 30 jobs. Request timing uses Rails' integration stack with local test authentication, excluding browser/network/provider latency.

## Results

| Metric | Before: 100 ms | After: 500 ms |
|---|---:|---:|
| Idle SQL statements/minute | 1219.0 | 552.6 |
| Immediate pickup p50 (ms) | 125.8 | 291.8 |
| Immediate pickup p95 (ms) | 260.2 | 643.7 |
| Immediate pickup max (ms) | 262.3 | 664.0 |
| First workspace request after 60s idle (ms) | 158.1 | 163.6 |
| Scheduled pickup lateness (ms) | 1176.3 | 865.9 |
| 30-job burst completion (ms) | 353.7 | 70.4 |
| Retry completion (ms) | 1922.9 | 1845.6 |
| Restart pickup (ms) | 13.6 | 15.2 |

Idle SQL volume fell 54.7% in these windows. Immediate-job p95 increased by 383.5 ms; the measured maximum was 664.0 ms. The first-request difference was 5.5 ms with 55 uncached SQL statements in each request. These single-window/single-request samples do not establish a statistical latency guarantee or improved burst performance. Thirty immediate jobs, the scheduled job, all 30 burst jobs, the two-attempt retry, and persisted work after restart completed in each run. Longer-tail production job latency remains unmeasured.

Raw samples: [before](queue-polling-before.json), [after](queue-polling-after.json).

## Availability and cold-start decision

Keep VERA compute always on. There is no local evidence that a Neon wake meets Leon's first-load requirement: the supplied wake estimate is 0.5–1 second. PostgreSQL stays running in this experiment, so this is a first request after **application inactivity**, not a simulated Neon suspend/resume. The 500 ms worker poll, 1 second dispatcher, process heartbeats and enterprise job every 30 seconds still prevent long query-free windows. Do not claim this saves compute hours or enables sleep.

Fresh jobs on an idle worker may wait up to roughly 400 ms more than before (500 versus 100 ms polling, plus database/OS work). Scheduled work retains the dispatcher's existing up-to-1-second delay, plus worker pickup. User-visible jobs must tolerate this bound before promotion from draft. If immediate-job feedback requires 100 ms pickup, retain the original interval rather than weakening the responsiveness requirement. Event-driven cross-process pickup would require a separately designed durable notification/queue architecture; Solid Queue 1.4.0 has no built-in PostgreSQL LISTEN/NOTIFY worker mode. A long sleep or application-only enqueue wakeup would miss jobs from other processes and is not used here.

No Neon/Render configuration, deployment, scheduler ownership or billing changes are included. No production frontend build is expected from this backend-only change; the existing separate frontend-ignore PR is #301. A host-configured deploy preview may still build on PR creation.

## Engineering gate and review handoff

Local environment: Mac mini M4, Ruby 3.3.7, PostgreSQL 16, Rails test mode. The backend suite ran on separate `vera_polling_test_20261119`; measurement ran on `vera_polling_bench_20261119`, sequentially after this task's suites/builds ended. Other machine services remained borrowed and untouched.

- Backend: 5,459 tests / 82,037 assertions, one failure, zero errors/skips. `MiaPersonaSetupProposalGuardTest#test_round_five_one_deadline_covers_every_candidate_and_salvage_retry` took 0.152407 s against a strict `< 0.15 s` assertion. An isolated rerun passed (1 test / 6 assertions). This does not convert the failed full run into a clean full gate. No unrelated test change is included.
- Ruby lint, Brakeman, gem vulnerability audit, Zeitwerk and diff whitespace checks passed. The new benchmark script also passed lint after its final changes.
- Frontend: design/privacy checks, lint, 226 files / 2,078 unit tests, build, production dependency audit and repository dependency audit passed. Existing large-chunk and unused audit-exception warnings remain. Build-generated sitemap date was restored. No frontend source changes are included.
- Browser/device and synthetic-document tooling gates were not run locally; CI/provider checks and review are separately reported on the draft. No whole-app or production acceptance is claimed. Actual background-queue acceptance is covered by the instrumented worker/dispatcher run, not a browser mock.

The PR must remain draft. Before promotion, review the measured idle-job pickup tradeoff against document-import and reminder UX, obtain current-head review, and resolve required CI gates (the ruleset still names a legacy `web` context). No merge/deploy is authorized by this queue item.
