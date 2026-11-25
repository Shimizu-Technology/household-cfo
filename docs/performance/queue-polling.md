# VERA queue polling measurement

Solid Queue worker polling changes from 100 to 500 ms. The dispatcher still polls every second. A worker can wake early when an occupied thread finishes.

## Reproduce safely

Use a dedicated local database, never `api_development`. The benchmark rejects other URLs and verifies Rails' resolved database before writing fixtures. No `.env` files or production credentials are needed.

```sh
cd api
export RAILS_ENV=test
export DATABASE_URL=postgresql://agent@localhost:5432/vera_polling_bench_20261119
export DATABASE_TEST_NAME=vera_polling_bench_20261119
ruby -ruri -e 'u=URI(ENV.fetch("DATABASE_URL")); abort "Unsafe DB" unless u.host == "localhost" && u.path == "/vera_polling_bench_20261119"'
bundle exec ruby -r ./config/environment -e 'configs = ActiveRecord::Base.configurations.configs_for(env_name: "test"); abort "Unsafe DB" unless configs.size == 1 && configs.first.configuration_hash.values_at(:host, :port, :database, :username) == ["localhost", 5432, "vera_polling_bench_20261119", "agent"]' &&
  bin/rails db:prepare
ruby script/benchmark_queue_polling.rb 0.1 > before.json
ruby script/benchmark_queue_polling.rb > after.json
```

Run these sequentially without other task-owned tests/builds. Both runs use the same application code and database; the argument selects the baseline interval, while the second run reads `queue.yml`. Assert the Rails-resolved configuration immediately before any additional `db:` command. Use the named database only if you own it and remove it after your run.

The script boots actual Solid Queue worker/dispatcher threads with production queue selection and concurrency, warms the authenticated workspace once, then counts uncached SQL statements (including transactions, excluding schema discovery) over 60 seconds. This is a local query-volume proxy, not measured compute hours or billing savings. Heartbeats and concurrency maintenance are included when they fall in the window. Production scheduler/supervisor and recurring business queries are excluded, so production totals will be higher. Thirty sequential arrivals sample varying poll phases. Scheduled latency is measured from the job's due time. Burst timing includes enqueue through completion of all 30 jobs. Request timing uses Rails' integration stack with local test authentication, excluding browser/network/provider latency.

## November 26 rerun

| Metric | Before: 100 ms | After: 500 ms |
|---|---:|---:|
| Idle SQL statements/minute | 1224.0 | 571.9 |
| Immediate pickup p50 (ms) | 118.3 | 348.6 |
| Immediate pickup p95 (ms) | 251.5 | 618.0 |
| Immediate pickup max (ms) | 254.2 | 653.6 |
| First workspace request after 60s idle (ms) | 93.4 | 51.9 |
| Scheduled pickup lateness (ms) | 548.2 | 1538.3 |
| 30-job burst completion (ms) | 267.2 | 84.7 |
| Retry completion (ms) | 1844.3 | 3127.0 |
| Restart pickup (ms) | 3.1 | 8.2 |

On merged main `a04fbb25`, idle SQL volume fell 53.3% and immediate-job p95 rose 366.5 ms. Both runs completed 30 immediate arrivals, the scheduled job, the 30-job burst, the retry and restart recovery. The workspace request issued 70 SQL statements before and 70 after. One local run per interval does not establish a production latency distribution.

Raw samples: [before](queue-polling-before.json), [after](queue-polling-after.json).

## User-facing latency

- **Document imports.** Upload returns the saved import while extraction runs in the queue. The Documents view checks status every 3.5 seconds. Extra pickup time can move a fast extraction past a status check.
- **Mia.** Text replies are generated in the request. With attachments, the composer explicitly waits for extraction, checks every 1.8 seconds and allows up to five minutes. A fast extraction near a poll boundary can take one extra check to appear. This is the most latency-sensitive path found.
- **Email.** Invitation and sign-in delivery requests call their providers inline. Challenge reminder emails run in background delivery on a five-minute recovery cadence, with no foreground completion wait.
- **Enterprise.** Scheduled admission sync runs every 30 seconds. Manual WorkOS refresh returns HTTP 202 and asks the admin to refresh status later.
- **Other background screens.** Bank sync, coach imports and persona evaluations expose asynchronous status. The extra idle pickup time can shift when a status poll observes completion.

These conclusions come from the controller, job and client paths. The local benchmark uses synthetic jobs and an authenticated Rails integration request. Provider timing and browser/device latency were not measured.

## Production impact

This cuts idle database queries about in half. It does not let Neon sleep or cut compute hours. Workers, heartbeats and the enterprise sync scheduled every 30 seconds keep VERA's compute always on by design for fast first load. The production scheduler and enterprise sync were outside the local query count. No hosting configuration changes are needed.
