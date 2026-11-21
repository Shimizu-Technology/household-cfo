# Bills and the year forecast

Implementation agent; November 21, 2026. Base: `bdc6e8716` (#355). Product context: `docs/product-design-brief.md`, `docs/mrs-mel-v1-feedback-implementation-plan.md`, `annual_budget_manager.rb`, `setup_bill_backfill.rb`, `actual_income.rb`, and the fictional Talun manifest. Household CFO helps participants plan their money; Mia reads approved Rails facts and never saves a financial change without the participant's action. No live model or paid service was used.

`Bill` adds a due-date and repeat contract, scoped to the household's current financial picture. A bill must be placed in one of her categories or explicitly marked "Not in any category plan". Debt minimums stay in debts and are read, not copied into bills; the form warns when a bill's name or amount matches a debt payment. Saves, edits, removals and paid/unpaid answers are explicit participant actions, audited as `bill.created`, `bill.updated`, `bill.removed`, `bill.paid` and `bill.unpaid` with the amount before and after. Members who can only read see no change buttons. Mia's action types do not include bills; Mia bill drafts are deferred.

## Forecast rules

Round 2 (review findings 1, 2, 5, 6 and the current-month note):

- **Opening cash.** Checking, savings and cash balances, all known and all dated the same day, in the current month or on the last day of the month before. Balances from different days, an earlier month, or with any unknown balance leave ending cash unknown and say why ("Your cash balances are from September 30. Update them in My Money to see ending cash.").
- **From a midmonth balance** (for example November 14), the rest of that month counts only what comes after that day:
  - Income: the month's plan minus income approved through that day, when approved statements cover every one of those days for every deposit account. Otherwise income is estimated by spreading the month's recurring pay over the days left, plus one-time income dated after the balance, and labelled as an estimate. Income schedules have no pay dates, so `IncomeTimeline.period_cents` with a date range returns a whole month of recurring pay; using it directly would count a paycheck already in the balance a second time.
  - Spending: for each category, the larger of what is left of the plan (plan minus spending recorded up to the balance date), its bills due after that date, and spending recorded after that date. Spending after the balance date is read the way Budget counts it (splits, minus refunds, with cash withdrawals moved to the purchases they paid for), so the balance never pays for the same purchase twice.
  - Debt minimums count in full, because their due dates are not saved.
- **Planned yearly costs and the surprise fund** (the `sinking_expected` and `sinking_unexpected` groups) with a saved bill: the monthly set-aside moves to her own savings, which is already counted as cash, so it is not money leaving the household. Only the bill counts, when it is due. A sinking category with no saved bill still counts its monthly plan, because nothing says when that money will be spent.
- **Other categories** count the larger of the plan and their bills due that month. In the current month, spending already recorded counts when it is larger than the plan.
- **Income in the current month** is the larger of income approved so far and the plan; the "approved so far" figure is shown. A complete past month would use approved income.
- **One-time bills.** A bill she marks paid never counts again. A one-time bill whose date has passed and that is not marked paid appears once, in the current month, as "Was this paid?" and counts until she answers. She can undo with "Not paid after all".
- Bills outside every category add to planned costs. A month whose costs are well above her usual month is marked "Higher costs than usual" (the same threshold the old outlook used: at least $100 or 10% above the median month).
- The first month that ends below zero is the short month. Named costs are contributors, not a claim that one cost is the sole cause. This is a month-end planning forecast, not an intramonth overdraft prediction or today's spendable cash.

## Where it shows

- **Home** shows one glance: the first short month and its costs, or "No month runs short through December" with December's ending cash, or what is still unknown, plus months with higher costs. "See every month and your bills" opens Budget with the forecast expanded and focused. The old grouped outlook was removed; the demo plan now sends a `year_forecast` too, so no screen renders the old path.
- **Budget → Year ahead and bills** has the month table, the plain "How this forecast works" list, and the bills editor. Saving, removing or answering "Was this paid?" refetches the plan in place: sections stay open, focus returns to Add bill, and the page does not reload. A refused save keeps what she typed. The remove confirmation sits beside its bill with focus on it. On a phone each month stacks as labelled rows, so nothing scrolls sideways.
- **Mia** answers only plain forecast and saved-bill questions. A worry, a payment report or a request for help choosing what to pay goes to the answers built for those ("We're short on rent this year, what do I do?", "Paid through December 15", "Paid $120 power, bills due scare me"). "Next big bill" means the largest saved bill due in the next 60 days (the one to get ready for); with nothing that soon, the next saved bill within 12 months. "What's due this month?" lists every bill. A month already past this year means the coming one, named with its year ("January 2027"). The search looks 12 months ahead across the year boundary. The year answer says when the short month includes estimates and no longer appends the technical rule. The plan is read once per message.

## Hand checks

Automated (`api/test/services/year_forecast_test.rb`):

- $1,000 opening + $200 income − $100 category plan = $1,100 in January, $1,200 in February. A linked $80 power bill does not add another $80. March adds a $1,500 one-time registration: −$200.
- **Registration with a set-aside:** $125 a month set aside in a planned-yearly-cost category and a linked $1,500 yearly bill due March 10. January $1,100, February $1,200, March −$200, April −$100. The year's costs are 12 × $100 + $1,500, not $125 × 11 + $1,500. With the bill removed, January's costs are $225 again.
- **Midmonth:** $1,000 dated January 15, $200 monthly pay, no statements: $200 × 16/31 = $103.22 estimated; utilities $100 − $30 spent leaves $70, below the $80 power bill due January 31, so $80 counts. January ends at $1,023.22, February $1,123.22.
- **Partial income:** $50 approved so far against a $200 plan counts $200; $300 approved counts $300.
- **Paid one-time bill:** a $300 repair due December 20 counts once in January ("Was this paid?"), never in February; marked paid, it no longer counts.
- Talun manifest: $100 opening, $180 income and $100 planned monthly, $186.45 power arrears May 7 and $690 repair September 22. May ends at $313.55; September is the first short month at −$56.45, naming the repair.

Browser (fictional local replay, November 21, 2026; $3,200 cash dated November 14, $5,400 monthly pay, $4,300 category plan including a $250 planned-yearly-cost set-aside, $90 debt minimums):

- Before bills: November $3,200 + $2,880 (pay estimated for 16 of 30 days) − $4,390 = $1,690; December $1,690 + $5,400 − $4,390 = $2,700. Home showed "December would end with about $2,700."
- Added "Car registration", $1,500, every year from December 10, in Expected sinking fund: November $4,140 out and $1,940 at the end (the set-aside no longer counts); December $5,640 out and $1,700 at the end.
- Added "Talun repair", $690, one time, November 5, "Not in any category plan": November $4,830 out, ending $1,250; December ending $1,010; "Was this paid?" shown once in November.
- "Yes, it was paid": back to $1,940 and $1,700. "Not paid after all" restores $1,250 and $1,010. Audit events recorded each answer.
- Mia: "Will we make it through the year?" → "No month runs short through December in this plan; December would end with about $1,700. Starting from your cash balances on November 14." "What's my next big bill?" → Car registration, $1,500, due December 10. "What's due in January?" → "You have no saved bills due in January 2027 …"

## Acceptance (agent executed, local replay stack on ports 3446/5446, production build)

| Scenario | Result |
| --- | --- |
| Category must be chosen; "Not in any category plan" explained; sinking hint | Passed (native required check blocked the save) |
| $1,500 registration example | Passed, numbers above |
| Midmonth balance (November 14) | Passed, estimate labelled |
| Past one-time bill: "Was this paid?", mark paid, undo | Passed, desktop and phone |
| Save, mark paid and undo without a page reload; focus returns to Add bill | Passed |
| Remove confirmation beside the bill, focused, on screen at 390 px | Passed (kept the bill) |
| Home summary and link to Budget with forecast expanded and focused | Passed, 390×844 and 1440×900 |
| Phone table without sideways scrolling | Passed (table 370 px wide in a 390 px viewport) |
| Mia year, next big bill, January | Passed on phone |
| Read-only member, debt warning, refused save keeps input | Component tests |

Evidence: [Home summary on phone](evidence/bills-forecast/phone-home-summary.png), [phone forecast](evidence/bills-forecast/phone-forecast.png), ["Was this paid?" on phone](evidence/bills-forecast/phone-was-this-paid.png), [desktop forecast](evidence/bills-forecast/desktop-forecast.png), [Mia on phone](evidence/bills-forecast/phone-mia.png). Chromium viewport testing, not Safari or a physical phone. No production deployment was requested.

Not covered in the browser: a midmonth balance with approved statements through the balance date (unit-tested with a stubbed reader; the coverage check reuses `ActualIncome`'s own statement-coverage rules), and a read-only member in a real session (no seeded read-only household).

Validation and cleanup results are recorded in the PR and final report. The lead owns review and merge; this worker does not merge.
