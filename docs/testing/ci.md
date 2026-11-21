# CI layout

Branch protection on `main` requires exactly four checks: `rails_security`, `rails_lint`, `rails_test` and `web`. Those names must report on every pull request, or merges block. Two of them are aggregates over the jobs that do the work.

| Required check | What runs under it |
|---|---|
| `rails_test` | `rails_test_shard (1/2)`, `(2/2)` and, on pull requests, `scorecard_ratchet`. The aggregate fails if any of them fails or is cancelled. |
| `web` | `changes`, `web-quality` and the `web-browser` matrix (four Chromium partitions and one mobile WebKit partition). Fails on any failure or cancel, or when a partition left no report. |
| `rails_security`, `rails_lint` | One job each. |

## Rails test shards

`api/lib/ci_test_shards.rb` splits the files `bin/rails test` runs (everything under `api/test` except `system/`) into two shards (`CiTestShards::SHARDS`, which a test keeps in step with the workflow matrix). Each file has a weight: its measured run time in seconds from `api/lib/ci_test_shard_weights.json` (files that take a second or more), or an estimate from its size for any file not listed. Files are dealt heaviest first to the shard with the least work so far, so the split is the same on every run and each file runs in exactly one shard (`api/test/lib/ci_test_shards_test.rb`, which also checks that the shards stay within ten percent of each other). Each shard has its own Postgres service and runs `db:prepare`. Shard 1 also runs `zeitwerk:check`. To list a shard's files locally: `cd api && ruby script/ci_test_shard.rb 2 3`. Size alone balanced badly (the first run took 4, 8 and 13 minutes of test time per shard), so the weights come from measured times. The shards run `bin/rails test -v`, which logs each test's seconds. To refresh the weights when the shards drift, download the shard logs of a green run and run `ruby script/ci_test_shard_weights.rb shard-1.log shard-2.log`; it rewrites `api/lib/ci_test_shard_weights.json` and prints the new shard loads.

Inside a shard, `parallelize(workers: :number_of_processors)` in `test/test_helper.rb` runs the tests in four processes, each with its own database. Don't call `parallelize` in a test class: it sets the executor for the whole run, so one class with `parallelize(workers: 1)` made its entire shard run in one process (18 minutes instead of 6, when CI ran three shards). `ci_test_shards_test.rb` fails if a test file calls it. A test that needs real commits sets `self.use_transactional_tests = false` and cleans up after itself; that is safe in parallel because every process has its own database.

## Browser test partitions

The `changes` job lists the partitions once (`CHROMIUM_SHARDS` and `WEBKIT_SHARDS` in its last step); the `web-browser` matrix runs that list and the `web` check requires a report from every entry. Each partition runs `web/scripts/browser-shard.mjs`, which lists the npm script's tests with `playwright test --list`, deals them round-robin, and writes the partition's share to a file for `--test-list`. It then lists again with that file and fails unless Playwright selects exactly the partition's tests, so every test runs in exactly one partition. Playwright's own `--shard` cuts the ordered list into equal-count runs, which put the slow tablet and phone tests together: one shard took 14 minutes and another 7. Round-robin keeps the partitions within a few percent of each other without timing data.

Each partition runs `PLAYWRIGHT_WORKERS` Playwright workers against one Vite dev server (the e2e sign-in and QA pages exist only in dev mode). The standard runner has four vCPUs, and a single worker's browser plus the dev server already use more than one, so extra workers mostly slow each test down: at three workers each test took about twice as long as at one. Every test gets its own browser context and mocks the API with `page.route`, so workers share no state; a test must not depend on another test having run first. Local runs keep `workers: 1` from `web/playwright.config.ts`.

CI's Chromium is branded Chrome, which `playwright install chrome` puts in `/opt/google`, so it isn't cached. WebKit's download in `~/.cache/ms-playwright` is cached under the installed Playwright version; apt still installs its system libraries, with the same retries and mirror fallback.

## Job count and time limits

The organization's free plan runs at most 20 Linux jobs at a time across all repositories, and other pull requests' runs compete for them. With eight Chromium and two WebKit partitions (21 jobs per run), each browser job took 12–15 minutes but runs waited 10–19 minutes for a slot, so a run took 38 minutes. CI therefore uses a few large jobs: after the short checks finish, a run holds seven jobs (two Rails shards, four Chromium partitions and one WebKit partition). The browser work is about 100 runner-minutes per run at three workers, so each browser job takes about 24 minutes. Raising `CHROMIUM_SHARDS` shortens a run while slots are free, and every extra partition holds one more slot for the whole run.

Every job sets `timeout-minutes` at about twice its usual time, so a hung job frees its slot instead of holding it for the default six hours. The browser jobs allow 50 minutes because the browser install's apt retries can add about 20 minutes during an Ubuntu archive outage.

Five long browser journeys (several cold loads of the app, or long Coach Studio flows) call `test.slow()`. With three workers per runner they ran at 20–32 seconds against the 30-second limit.

## Browser tests skip when they can't be affected

Every browser test mocks the API (`web/playwright.config.ts` sets `VITE_API_BASE_URL=http://api.test`). The `changes` job compares a pull request with its base. The browser jobs run when a file under `web/`, a root package or lock file, or `.github/workflows/ci.yml` changed, and on every push to `main`. Otherwise they are skipped and the `web` check reports success only because `changes` succeeded and the browser jobs were skipped. `web-quality` (lint, types, unit tests, build, audits) runs on every pull request.

## Scorecard ratchet

See [scorecard.md](scorecard.md) for how the base branch's ratchet judges the baselines and when a pull request must explain a ratchet change.
