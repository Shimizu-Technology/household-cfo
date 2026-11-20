# Statement save performance

Execution owner: implementation worker, November 20, 2026. Measured starting base: `4ec5dbc5354918cc77d7c96c64d4d758d4289388`; final integration base after receipt-tender PR #337: `b6dea2c8b077dcc9d85841c124fdf7ef7baa17ac`.

Participants approve statement lines; Budget projects approved categorized outflows and Mia reads approved source versions. Preserve exact facts, stale/duplicate guards, append-only history and atomic saves. Sources: `docs/source-review-domain.md`, `SourceReview::LineApprover`, `OverlapDetector`, `ProjectionCorrector`, `docs/testing/scorecard.md`.

Acceptance is agent-executed affected-flow QA: measure real single/bulk saves, verify saved spending, preserve scorecard JSON exactly, and pass related tests plus the full Rails/security/style gate. Desktop Chromium is required here; production and mobile Safari are not verified.

## Measurements

The transactional fixture creates 1,632 invented approved historical lines across 48 monthly statement account sections covering a year. Setup is outside timing. Measured saves use the production domain under the household lock and create real spending projections. Query counts include transaction/locking SQL.

| Save | Before seconds / queries | After seconds / queries |
| --- | --- | --- |
| One line | 0.406 / 248 | 0.250 / 242 |
| 22 lines | 2.434 / 2,860 | 2.206 / 2,456 |
| 100 lines | 10.085 / 12,532 | 9.941 / 10,667 |

An earlier run measured 0.162 / 1.355 / 4.384 seconds for these sizes; the table records the final isolated run after the duplicate-page fix. The 100-line timing varies substantially across runs.

The typical page meets the three-second target locally; the 100-line stress case still exceeds it. Regression assertions bound annual allocation reads regardless of page size and reject the former unbounded current-picture event read. They avoid wall-clock assertions.

The real local stack on ports 3424/5424 used a fresh fictional participant/household and uploaded the invented Bank of Guam CSV through the UI. Desktop Chromium approved individual movement/refund/category answers and all 23 ready lines, verified all 27 lines saved, then checked August Budget spending of $2,326.66. Before and after both passed. Bulk HTTP duration fell from 1.521 to 1.448 seconds. This smaller browser fixture is separate from the large-history fixture.

Evidence: `/Users/agent/work/hcfo-evidence/perf-statement-save-speed/` outside this public repository. Shared preview twice failed with `net::ERR_CONNECTION_REFUSED`; QA used headless Playwright. Temporary braced-variable corrections worked around Unicode-ellipsis interpolation in the local launcher and were restored afterwards. No web or launcher changes are included.

## Rollout and limits

Each locked page save provisions annual budget data once per affected year and reuses its period map. Success and failure clear the request cache. Other projection callers retain their existing behavior. Overlap queries narrow source, approved and pending amount/date matches while preserving physical artifact/locator and reviewed-reference matches independently of amount/date. Existing duplicate rules and latest-source filtering still apply.

The migration adds concurrent household/amount/date indexes on source events and reviewed versions. It changes no records or accounting baselines. These measurements do not establish production latency. Final gate after rebase at implementation `330abe75` (later commits change only these notes): 5,569 Rails tests / 82,974 assertions, zero failures/errors/skips (585.2 seconds); expanded related batch 164 tests / 1,424 assertions; isolated benchmark 1 test / 17 assertions; RuboCop 1,493 files clean; Brakeman zero warnings; Zeitwerk passed. Full and fast scorecards passed `RATCHET=1` with parsed JSON exactly identical to both committed baselines. No baseline files changed.

QA case S1 (required, participant, desktop Chromium 1366×900): fresh seeded household → upload fictional CSV → save individual answers → approve all ready lines → verify saved review and August Budget. Passed on main and final implementation: 27 saved lines and $2,326.66. Mobile Safari and production remain not run. Earlier full-suite attempts exposed a removed internal helper call and a duplicate-page query regression; the test was updated to exercise candidates, the read-only page was batched, and the final complete suite passed. Original failure logs remain in external evidence. A rebased run and isolated reruns also missed the unrelated Mia deadline test’s 150 ms wall-clock bound (including 150.9 ms); it passed unchanged in the final complete suite. No deadline assertion was weakened. Both scorecards were repeated after rebasing and are exactly identical to the updated committed receipt-tender baselines. Browser acceptance also passed again on the rebased code.

The local stack was stopped and reset. Owned test databases are dropped before delivery; the lifecycle session has no active owned runtime resources. The branch/clone remain available for the lead's review and merge. The host's shared-guidance checker could not run because `~/.config/shimizu-technology/agent-context.json` is absent; applicable synced guidance was read directly.

## Round 2: database round trips

The local round-1 timings hid the production cost: each query crosses from the Render app to Postgres. Round 2 batches the request's reads under the household lock. It reuses the participant plan's events, heads, accounts and categories; checks all operation permissions against one resolved runtime; preloads identities, pending drafts, existing spending and legacy drafts; and discovers affected revisions once. The overlap superset covers source facts and edited amount/date facts, and receives every newly approved head before the next line. Coverage is computed once after the writes. Annual plan provisioning still runs once per affected year, with existing allocation keys read together. All model validations, fact checks, optimistic head/draft checks and duplicate rules still run.

Measured on the same 1,632-line fictional history at implementation `f2140a55`, based on `b6dea2c8b077dcc9d85841c124fdf7ef7baa17ac`:

| Lines | Round 1 local seconds | Queries | Queries/line | Estimated seconds at 10 ms/query | Round 2 local seconds | Queries | Queries/line | Estimated seconds at 10 ms/query |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 0.250 | 242 | 242.00 | 2.42 | 0.079 | 60 | 60.00 | 0.60 |
| 22 | 2.206 | 2,456 | 111.64 | 24.56 | 0.198 | 233 | 10.59 | 2.33 |
| 100 | 9.941 | 10,667 | 106.67 | 106.67 | 0.936 | 857 | 8.57 | 8.57 |

The estimate counts only query round trips, not execution, CPU, rendering or other network time. SQL notifications include transaction statements. The regression test caps saves at 60 / 250 / 875 queries. `PROFILE_SAVE=1` writes grouped SQL and application caller locations to `/tmp/hcfo-query-profile-{size}.txt`. The remaining linear cost is eight writes per projected line: head, draft, approved version, transaction, split and projection inserts, then head and draft updates. This keeps append-only history and every model validation.

Chromium on the real local stack (3424/5424) uploaded the fictional Bank of Guam CSV, linked its account, answered coverage and all four questions, then approved the remaining 23 lines. The bulk HTTP request took 0.268 seconds on `f2140a55` (earlier round-2 runs took 0.297 and 0.402) versus 1.448 seconds in round 1 (1.521 before the PR); all 27 lines saved and August Budget showed exactly $2,326.66. Production and mobile Safari are not run. Shared preview initially opened localhost, which failed CORS; the same browser passed using the launcher's 127.0.0.1 origin. The launcher's existing Unicode interpolation issue again needed a temporary local workaround; it was restored and is excluded from the PR.

The follow-up category regression at `612965c8` proves that a category snapshot on the first line retains the metadata seen before Budget provisioning, while subsequent lines see any metadata that provisioning refreshed, just as separate domain approvals do. Both full and fast scorecard JSON outputs are byte-identical to their committed baseline files (SHA-256 `77e9b71b12ae66ce3867e6ffafa8dc0e3b46aa53598da1b3e7b54fef65984693` and `80f859b3f1d4d8ae68937a9849777429fb50aa805bcd4f2b162e309cf8d026d9`).

Final gate on source `f2140a552f85273b780542dc9789cc19cc99af22`: 5,571 tests / 82,985 assertions, zero failures/errors/skips (326.2 seconds, four workers, `PGGSSENCMODE=disable`; no fork crash). Expanded related batch: 200 tests / 1,670 assertions. Isolated benchmark after the final fetch/rebase: 1 test / 23 assertions, with the timings above. RuboCop: 1,493 files clean; Brakeman: zero warnings; Zeitwerk passed. Both scorecards were repeated after the final runtime fix and their complete JSON bytes remain identical. An earlier serial run had the already documented unrelated Mia deadline failure (190 ms against 150 ms); that test passed unchanged on rerun and in the final complete suite. No deadline assertion was changed.

The final alias regression checks that correcting a line marks its aliases' coverage pending, while an unchanged line's alias remains untouched. Alias and economic-link revision dependencies are discovered once per event and marked once after the writes. Browser acceptance S1 was repeated on `f2140a55`, including all saved lines and the exact Budget result. The local stack was reset, every owned browser tab and server was closed, and the task test databases (including four worker copies) were dropped. The clone and branch remain for the lead's review; this worker did not merge.

## Round 3: review fixes

Rebased onto B4 on main (`fa9946f5`). Coverage resolves identities directly, including account sections with no events. Save plans use the page's external-statement candidate scope. Each line expands overlap candidates from its actual reviewed facts when its amount/date differ from the source, including saved refunds answered as read. Validation stays in line order. Duplicate event IDs are rejected before writes. Both concurrent indexes use `if_not_exists: true`.

`Domain#record_write!` updates known heads and version counters after every approval, including counterpart approvals. External writers can omit the head to invalidate and reload that event's head, drafts, sequence, actuals and legacy drafts. Initial empty head/actual entries remain known empty. Stage writes update overlap pending state, approval writes update approved state, and voids clear actuals. Account/economic-link writes clear overlap/account checks and rediscover revision dependencies. Identity heads are reloaded once per account under the household lock and rechecked after invalidation. Both coverage checks read fresh records; RevisionApprover locks head rows again. Import metadata is reloaded before pending/coverage metadata is merged. B4's confirmed-purchase validation remains fresh per approval.

The six issue regressions were run against the rebased pre-fix source: all six failed (three failures, three errors). They pass with the fixes. Another regression checks that coverage preserves metadata written after its import object was loaded. The counterpart regression performs an ordinary approval through a second domain instance mid-batch, invalidates that event, then approves another version through the batch. It verifies sequence, supersession, spending replacement and void.

| Lines | Round 2 queries | Review fixes queries | Local seconds | Queries per line | Estimated round trips at 10 ms/query |
| --- | --- | --- | --- | --- | --- |
| 1 | 60 | 94 | 0.063 | 94.00 | 0.94 s |
| 22 | 233 | 289 | 0.182 | 13.14 | 2.89 s |
| 100 | 857 | 991 | 0.752 | 9.91 | 9.91 s |

Counts include B4's fresh purchase matching and restored coverage reads/locks. Regression budgets are 100 / 300 / 1,125. The 22-line page retains the reduction from 2,456 queries to fewer than 300. Production latency and browser/Safari acceptance were not remeasured in this round; controller tests exercise saved outcomes and error responses with fictional data.

Review gate: the corrected full run completed 5,586 tests / 83,090 assertions in 344.7 seconds with four workers and `PGGSSENCMODE=disable`, zero errors/skips and one failure: the unchanged Mia deadline test took 191 ms against its 150 ms limit. The first serial attempt used a database name without the scorecard-required `_test` marker: 5,586 tests / 83,073 assertions in 920.6 seconds, two scorecard guard errors and the same deadline failure (155 ms). The corrected run removed both setup errors. No deadline assertion was changed, and neither run crashed PostgreSQL.

Both standalone scorecards passed `RATCHET=1` with complete JSON bytes identical to committed baselines: full SHA-256 `83217e66308f255e1f54d8ad70b5f911bd15fcf00af8b9e8f87716119c441620`, fast `568c3f2856f5828f267c4d2d2ec1c24b202898b70f58033435fba59689f4450c`. Baselines are unchanged. RuboCop checked 1,497 files without offenses; Brakeman reported zero warnings; Zeitwerk passed. The index migration ran twice successfully.

At the final fetch, main remains `fa9946f53c1fff2aa7630a742d4c008a1f939c37`; #338, #339 and #342 are unmerged. The lead must retest actual pairing/unpairing, a 22-line page containing a pair and cash drawdowns after #339/#342 land. The simulated counterpart-write regression passes before those merges. This implementation worker does not merge.

Final affected gate, including the unchanged Mia deadline test file: 206 tests / 1,675 assertions, zero failures/errors/skips (61.9 seconds). This run follows the last dependency-lock adjustment. Query counts remained exactly 94 / 289 / 991. Its local save times were 4.836 / 4.964 / 5.618 seconds, compared with the earlier isolated 0.063 / 0.182 / 0.752 seconds shown above; local elapsed time varied substantially while database round trips stayed identical. The full-suite timing failure remains recorded and is not presented as a clean full run. Final RuboCop and Brakeman checks also passed.

All seven owned test databases (three named databases and four parallel worker copies) were dropped. The lifecycle session has no active owned resources; the shared PostgreSQL server remains available. The clone/branch are retained for the lead's review and merge.
