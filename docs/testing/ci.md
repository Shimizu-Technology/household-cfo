# CI layout

Branch protection on `main` requires exactly four checks: `rails_security`, `rails_lint`, `rails_test` and `web`. Those names must report on every pull request, or merges block. Two of them are aggregates over the jobs that do the work.

| Required check | What runs under it |
|---|---|
| `rails_test` | `rails_test_shard (1/3)`, `(2/3)`, `(3/3)` and, on pull requests, `scorecard_ratchet`. The aggregate fails if any of them fails or is cancelled. |
| `web` | `changes`, `web-quality` and the `web-browser` matrix (Chromium shards and mobile WebKit). Fails on any failure or cancel. |
| `rails_security`, `rails_lint` | One job each. |

## Rails test shards

`api/lib/ci_test_shards.rb` splits the files `bin/rails test` runs (everything under `api/test` except `system/`) into three shards. Each file has a weight: its measured run time in seconds from `api/lib/ci_test_shard_weights.json` (files that take a second or more), or an estimate from its size for any file not listed. Files are dealt heaviest first to the shard with the least work so far, so the split is the same on every run and each file runs in exactly one shard (`api/test/lib/ci_test_shards_test.rb`, which also checks that the shards stay within ten percent of each other). Each shard has its own Postgres service and runs `db:prepare`. Shard 1 also runs `zeitwerk:check`. To list a shard's files locally: `cd api && ruby script/ci_test_shard.rb 2 3`. Size alone balanced badly (the first run took 4, 8 and 13 minutes of test time per shard), so refresh the weights when the shards drift: run `bin/rails test -v`, add up each test class's seconds per file, and keep the files at one second or more.

## Browser tests skip when they can't be affected

Every browser test mocks the API (`web/playwright.config.ts` sets `VITE_API_BASE_URL=http://api.test`). The `changes` job compares a pull request with its base. The browser jobs run when a file under `web/`, a root package or lock file, or `.github/workflows/ci.yml` changed, and on every push to `main`. Otherwise they are skipped and the `web` check reports success only because `changes` succeeded and the browser jobs were skipped. `web-quality` (lint, types, unit tests, build, audits) runs on every pull request.

## Scorecard ratchet

See [scorecard.md](scorecard.md) for how the base branch's ratchet judges the baselines and when a pull request must explain a ratchet change.
