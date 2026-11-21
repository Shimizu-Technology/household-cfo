# Actual income against plan

App context (2026-11-21, base b05f92ff): Household CFO supports participant households reviewing statement lines, making an annual plan, and asking Mia about their money. Sources: README.md, docs/testing/local-stack.md, approved_source_reader.rb, source_review_version.rb, household_transaction.rb and income_source.rb. Statement approvals are financial facts; income sources/schedules are plans. HouseholdTransaction is the purchase ledger. Canonical approved lines already resolve duplicate matches. Refunds and own-account transfers are separate event types.

Agent-executed affected-flow acceptance: approved positive income totals match the Talun manifest month by month; missing evidence stays unknown; transfers, refunds, duplicate representations and old financial generations do not inflate income. Home and each Budget report month compare approved income with the plan and disclose partial coverage/open months. Mia uses Rails facts, including months before the plan begins. Required browser dimensions: Chromium 390×844 and 1440×900, local replay with original Talun files, upload and approval through Statements, then Home/Budget/Mia. No live model calls or paid services. Real iPhone/Safari excluded on this host.

Initial acceptance evidence: reviewed the original `bog-2026-11-phone-1.png` through Statements (Talun checking ending 6824). Approved the $1,650 income and category questions; the $500 own-account transfer did not count. Home and Budget show $1,650 actual / $5,400 planned, Budget difference −$3,750. Mia answers the same Rails facts and warns that the month is open and accounts/days are incomplete. Saved screenshots cover all three screens at both required dimensions. The initial Playwright upload succeeded but its stale “Choose account” expectation failed (the recorded account was linked automatically); continued the review in the shared browser. Real phone/Safari and live reader behavior are not tested.

## Round 2 (review fixes)

What counts as income:
- Only money into a deposit account counts. That means an asset account not linked to a retirement, investment or property account. Money into a card or loan never counts, even if it was saved as income before this change. The spreadsheet reader types a positive card line as a card payment ("AUTOPAY PAYMENT", "MOBILE PAYMENT") or, with no payment wording, as unknown (a question). The statement reader never types money into a card as income. A card line already typed income is asked "Is this a payment on your own card or loan?", and "Yes" saves it as a card payment.
- Positive interest on a deposit account counts as interest earned. There was no reason in the code to leave it out, and the Talun manifest has no positive interest, so the scorecard is unchanged.
- Pay, payroll, salary, wages, bonuses, commissions, benefits, pensions, Social Security, tax refunds, dividends and interest stay ready to approve, unless the line also has own-money wording. Any other line read as income gets one question, "Money you earned or received, or your own money moving back?". That covers cash, ATM, branch or mobile deposits, "from savings/checking", transfers, the word "own", PayPal/Venmo/Cash App/Zelle/Apple Cash/Apple Pay credits, and a deposit with no payer named. The answers are "Earned or received" (saved as income), "My own money moving back" (saved as a transfer, so it isn't income) and "Something else" (the line form, where she can pick a refund). If the line matches a move out of another of her accounts, the existing pair question asks about both lines instead.
- Positive Zelle and "Received from" lines now get the person question, "Your own account or someone else?", for money coming in as well as going out. Someone else saves the line as income; own account saves it as a transfer. A line left waiting on an ownership answer (`ownership-needed:`/`overlap-cleared:`) counts nowhere.

Coverage:
- A month is complete only when every deposit account's approved, complete statements together cover every day of it, and no active checking, savings or emergency-fund account is missing statements. Card, retirement, investment and property accounts don't affect it.
- A month that is only partly covered and adds up to $0 reads "None approved yet. Your approved statements don’t cover all of this month." It never shows $0.

Display:
- Home and Budget say "$X in so far" only while the month is open. A closed month says "$X came in". Budget shows "Difference from plan" only for a closed, completely covered month.
- Mia's year answer gives one total for the known months. It names the partly covered and not-known months, and the months before the plan starts, in 3–5 sentences.

Performance: the plan carries approved income lazily (`ActualIncome::Months`). It reads the current picture's approved lines once, and only when a month is shown. Home and Mia reuse the plan's months, and a Mia year answer builds one plan. On a household with three approved statements, measured by the same test: Home went from 2 statement reads and 341 queries to 1 and 267, and a Mia year turn from 22 reads and 2,054 queries to 1 and 212.

Scorecard: `app_actual_income` now records `known`, and an unknown month has `actual_cents: null` with the whole expected amount as its error, never a $0 match. The ratchet treats a known month becoming unknown as a regression. Browser screenshots in `evidence/actual-income/` predate round 2: the Budget screenshot still shows the old open-month difference line.

## Round 3 (ownership answers on approved deposits)

Context: continued from rebased PR head `2ba27758648beca90e052353b5ae516684bd0833`, on Ruby 3.3.14. This round changes backend review and income facts only; the existing Home/Budget coverage-note display consumes the same response. Fictional strings and committed offline Talun recordings only; no production records, paid services or live model calls.

- An included, positive deposit with an unfinished ownership reference keeps its month partial, even when the statement coverage approval is complete. Income excludes the waiting line. The coverage note counts the waiting deposits and directs her to Review: “1 deposit still needs your answer in Review, so it isn't counted yet.” Mia repeats that note for a month and totals waiting deposits for a year.
- Legacy included income approvals now use the same money-in predicate as new lines. An ambiguous/own-money description without a recorded `received:` answer reopens as the money-in question and stays out of actual income. Reads preserve every existing approved version. Answering preserves the facts she previously corrected (including the posted date). “Earned or received” saves income normally; “My own money moving back” saves a transfer. Payroll stays finished. Evidence is preloaded through the review head.
- Google Pay, Samsung Pay, Amazon Pay and spaced PAY PAL now count as wallet wording even though “pay” also appears in earned-income wording.
- Statement completeness and income completeness remain separate. An ownership question makes income partial without falsely claiming that otherwise complete statements miss calendar days.

Agent-executed affected-flow regression cases:
1. A complete July statement has an approved ATM deposit and approved payroll. Review reopens only the deposit; income counts only payroll, reports one waiting deposit, and Mia's month/year answers disclose it. The old approval ID remains unchanged until the participant answers; earned/received then counts the deposit, preserves its corrected date, and finishes review.
2. A complete statement contains positive transfer/income lines with `ownership-needed:` and `overlap-cleared:`. July stays partial and the note counts both waiting deposits.
3. All four wallet names trigger the money-in question.

All three new tests failed against the incoming head (three failures, no errors). The initial focused domain run passed 83 tests / 495 assertions. An attempted preload optimization used a delegated method as an association; the broader run caught it and was stopped. The corrected preload follows `source_review_head.financial_source_event`. A concurrent related-test/scorecard run encountered a database lock and was stopped; final scorecards use their own database.

Final-code regression cases pass: 3 tests / 22 assertions. RuboCop passes 1,523 files; Brakeman reports zero warnings; Zeitwerk eager loading passes.

The additional `scorecard:prove_injections` task fails during its untouched baseline replay with `Domain::StaleReview` at `LineApprover#apply!`, before any injection runs. Loading all five affected services from incoming head `2ba27758` in a separate Rails process reproduces the same error at the same baseline call. The injection proofs remain unverified; the required fast/full ratchet replays are recorded separately below.

The final fast/full reports both pass `RATCHET=1` and exactly equal their committed baselines, including the answers-only view. No baseline regeneration or override change is needed. Careful-user income, January–December, is $7,685; $7,500; $7,827.50; $7,500; $7,500; $7,596; $7,500; $7,942; $7,500; $7,500; $7,713; $7,500 (annual $91,263.50), every month known with zero manifest error. Careful spending stays $44,242.95, double counts 0 and leakage $0. Answers-only metrics are unchanged, including their existing spending/double-count errors. Decisions remain 644 careful / 628 answers-only for the year and 79 / 77 for the fast subset; the existing full-year fewer-than-200 target remains unmet.

A final rerun after preserving corrected facts encountered a pathological PostgreSQL plan in the existing 300-copy duplicate-review test. The stopped focused/full runs were not counted as passes. With `PGOPTIONS='-c jit=off -c enable_nestloop=off'`, that exact test passes 1 test / 12 assertions in 6.9 seconds; final suite/focused counts below use those same connection settings, without repository/database configuration changes.

Final full Rails suite: **5,788 tests / 85,136 assertions**, zero failures, errors or skips (347.4 seconds, four workers). Final related domain/statement-approval/Mia batch: **180 tests / 1,645 assertions**, zero failures, errors or skips. These run on the final API/test code; the final documentation/reporting update changes no runtime behavior.

Cleanup: all started test/replay jobs finished or were explicitly stopped and reaped. The seven owned databases (`income_round3_test`, its `_0`–`_3` workers, `income_round3_related_test`, `income_round3_scorecard_test`) were dropped. Lifecycle session `manual-20261121-183215-64840-b9b3` reports no active owned resources. No servers or browser tabs were started. Shared PostgreSQL and protected services remain available; the branch/checkout is retained for the lead. No merge or deployment.

Browser checks, real iPhone/Safari, live extraction/model behavior and deployment were not rerun in round 3. The older screenshots do not establish acceptance of these new ownership states. No web source changed, so the conditional web build gate does not apply.
