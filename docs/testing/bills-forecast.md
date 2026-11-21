# Bills and the year forecast

Implementation agent; November 21, 2026. Base: `bdc6e8716` (#355). Product context: `docs/product-design-brief.md`, `docs/mrs-mel-v1-feedback-implementation-plan.md`, `annual_budget_manager.rb`, `setup_bill_backfill.rb`, `actual_income.rb`, and the fictional Talun manifest. Household CFO helps participants plan their money; Mia reads approved Rails facts and never saves a financial change without the participant's action. No live model or paid service was used.

The existing category rows and setup backfill have amounts but no due-date/cadence contract. `Bill` adds that contract, scoped to the household's current financial picture. A bill can share a category with a spending plan. Debt minimums stay in debts and are read, not copied into bills. Mia's action types do not include scheduled bills; creating Mia bill drafts is deferred rather than extending the write protocol in this change. Manual saves and confirmed removals are audited.

Forecast rules:

- Current month through December, with monthly income schedules. Approved actual income replaces planned income in the current month when known; partial actuals are labelled. Previous months are not projected from today's balance.
- Opening cash requires known active liquid-account balances dated at the previous month's end. Unknown amounts or mismatched dates leave cash unknown, preventing a whole month's income being added to a midmonth balance again.
- Each active category counts the larger of its planned allocation or its linked bills due that month. Unlinked bills add to spending. This includes sinking-fund category allocations. Debt minimums add exactly once. Unknown debt minimums or missing allocations leave outflow unknown.
- A one-time bill still saved from an earlier month counts as overdue in the current month. Recurring bills begin at their first due date; days 29–31 clamp to the last day of shorter months. Repeats are anchored, not shifted by February.
- The first negative cumulative month is the short month. Named costs are contributors, not a claim that one cost is the sole cause. This is a monthly planning forecast, not an intramonth overdraft prediction, a payment tracker, or today's spendable cash.

Hand checks:

- Opening $1,000 + $200 income − $100 category plan = $1,100 in January, $1,200 in February. A linked $80 power bill does not add another $80. March adds $1,500 registration, ending at −$200, with registration named.
- Talun manifest: $100 opening, $180 income and $100 planned spending monthly, plus $186.45 power arrears on May 7 and $690 appliance repair on September 22. May ends at $313.55; September is the first short month, −$56.45, naming the repair. The dates in this scenario are the manifest payment dates entered explicitly as planned bill dates; it does not infer April's original due date from May's paid transaction.
- Browser fixture: $3,200 opening balances explicitly dated October 31, $5,400 income and $4,390 out monthly. A participant-added $6,000 December repair gives November $4,210 and December −$780.

Affected-flow acceptance (agent executed, fictional local replay, ports 3426/5426):

| Scenario | Acceptance |
| --- | --- |
| Add/edit a bill, reload, verify saved amount and cadence | Desktop and phone create/edit/reload passed |
| Remove a bill only after confirmation; forecast changes back | Desktop and phone passed |
| Year table, named first short month, Home placement | Desktop 1440×900 and phone 390×844 passed; phone table scrolls horizontally |
| Ask Mia about the year, next big bill, and March | Passed; Rails gives December and $780, the saved $6,000 bill on December 22, and no saved March dates with an explicit unknown warning |
| Unknown dates/balances, recurrence, actual income, Talun arrears/repair | Automated coverage |

Evidence: [phone forecast](evidence/bills-forecast/phone-forecast.png), [desktop forecast](evidence/bills-forecast/desktop-forecast.png), [Mia on phone](evidence/bills-forecast/phone-mia.png). This is Chromium viewport testing, not Safari or a physical phone. No production deployment was requested.

During QA, the ordinary build replaced the files served by preview and a reload could not load the program. Restarting through the guarded local-stack production-build launcher restored the correct isolated configuration; phone create/edit/remove was retested successfully.

Validation and cleanup results are recorded in the PR and final report. The lead owns review and merge; this worker does not merge.
