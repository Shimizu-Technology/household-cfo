# Store and repeated-file answers (C4, round 2)

At base `ff4ea532d49ab5da3e10b01395d8214585ebb43d`, participants approve statement lines before they count in Budget or Mia. `ParticipantPlan` supplies the screen's questions; `LineApprover` saves explicit answers through ownership, version, overlap and projection guards. Fictional fixtures only; no paid services or production data.

A statement now offers one answer for its unambiguous copies of approved statement lines. Eligibility requires the same reviewed tracked account, signed amount, cleaned store, and a posted date within the existing three-day window. Exactly one approved candidate must match. Stale account identities, pending corrections, receipt matches, person-payment questions and offered transfer pairs stay individual. Eligibility is recomputed under the household lock when she taps “Leave them out.” Each line is saved as `leave_out` through the existing batched approver, in one atomic request, up to 1,000 lines. Nothing counts. “Review them one by one” saves nothing. “See all” retains individual reopening.

Store-category questions span current statements. The displayed group names its statements and shows dates and amounts in its expanded details. One chosen active category submits explicit membership and expected heads. The server checks household ownership, generation, current revision, store and question eligibility, then uses normal guarded approvals for each revision in the same transaction. A stale line rolls everything back. Other statements' coverage answers are never inferred. Existing approvals are not recategorized; retries preserve the category already saved.

The combined browser checks also exposed an older statement's save callback overwriting a new upload selection. The callback now preserves the explicit selection. Reopening “Same purchase” with “Different purchase” now permits the existing guarded undo path for a saved matched line.

`LOCAL_STACK_WEB_BUILD=1 bin/local-stack up` builds and serves the production-optimized web bundle with the local API. The explicit local-stack test-auth option requires both the page and API to use loopback. Ordinary production builds still fail closed without secure authentication. No deploy preview or production publish is needed.

## Scorecard

Both views use the production repeated-line plan and approval path. A file answer is one decision. Store groups use production membership; the replay imports and finishes statements in order, so no other statement has pending category questions when it answers a store. It does not invent cross-statement savings for future imports.

| Decisions | Round 1 | Round 2 |
| --- | ---: | ---: |
| Full careful | 690 | 581 |
| Full questions-only | 670 | 567 |
| Fast careful | 80 | 75 |
| Fast questions-only | 78 | 73 |

The under-200 annual target remains unmet. Careful review retains 201 individual duplicate questions, 80 account identities, 80 page approvals, 68 transfer-pair answers and other questions. Eight file answers replace 116 individual duplicate answers; fewer page approvals explain the remaining decrease. Weak or multiple matches and other guard questions are deliberately retained.

Annual careful spending is $44,242.95 and income $91,263.50: both errors $0, double counts 0, leakage $0. Questions-only spending remains $44,278.69 (+$35.74), income $91,263.50 (error $0), double counts 2, leakage $0. Fast spending is $6,406.23 and income $13,563 in both views, with zero errors, double counts and leakage. No financial ratchet metric worsened.

Scorecard baseline override: regenerate full and fast baselines with `Scorecard::Runner` for the explicit repeated-file answer. The new `repeated_file` decision/question counters replace individual duplicate questions; only those new counters increase against round 1. Financial errors, double counts and leakage are unchanged. The under-200 threshold is unchanged and still fails.

## Verification

Evidence: `/Users/agent/work/hcfo-evidence/feat-categorize-store-once-r2/`. The browser acceptance uses the real local API, a production build and ports 3429/5429. It covers cross-statement saving, explicit repeated-file consent, individual review, saved exclusions, reopening and unchanged spending, desktop and phone layouts. WebKit and real-device Safari are not run: WebKit cannot start in this machine's headless agent account.

The 300-line exclusion query test verifies one guarded request, all 300 saved exclusions and an unchanged retry. The final measured run used 1,598 queries (5.33 per line), below the existing C2 purchase-save cost of 991 queries for 100 lines. The final run and gate counts are recorded in the PR body and evidence logs.

Final web gates: TypeScript, eslint, ordinary production build, 2,156 unit tests and 91 affected desktop e2e scenarios passed. The combined local-stack suite passed all nine Chromium scenarios against the local production build, including cross-statement membership and its saved categories, repeated-file consent and individual review, unchanged spending, reopening an excluded line, and desktop/390px/320px layout. The original shared-fixture total assertion now measures its own added spending; phone reads compare with the current ledger and search the older upload rather than assuming it remains on the first history page. Advisory Impeccable returned no findings.

Final Rails full run: 5,693 tests / 84,265 assertions, zero failures/errors/skips with four workers; no PostgreSQL fork crash or persona deadline flake. The earlier serial run completed 5,692 tests / 84,233 assertions with one “Same purchase” undo failure, subsequently fixed. Related tests passed 198 / 1,799 assertions; final strict-match, malformed-input, rollback and query checks passed 4 / 33 assertions. Both final scorecards passed `RATCHET=1`; RuboCop passed. All task databases (including four test-worker databases) were dropped, `bin/local-stack reset` ran, and lifecycle status showed no owned resources. The PR remains a draft because the annual decision target is unmet and new-head CI/review still needs assessment.
