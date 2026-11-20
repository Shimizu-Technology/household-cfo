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
