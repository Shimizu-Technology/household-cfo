# Bills and the year forecast

Implementation agent; November 21, 2026. Base: `bdc6e8716` (#355). Product context: `docs/product-design-brief.md`, `docs/mrs-mel-v1-feedback-implementation-plan.md`, `annual_budget_manager.rb`, `setup_bill_backfill.rb`, `actual_income.rb`, and the fictional Talun manifest. Household CFO helps participants plan their money; Mia reads approved Rails facts and never saves a financial change without the participant's action. No live model or paid service was used.

`Bill` adds a due-date and repeat contract, scoped to the household's current financial picture. A bill must be placed in one of her categories or explicitly marked "Not in any category plan". Debt minimums stay in debts and are read, not copied into bills; the form warns when a bill's name or amount matches a debt payment. Saves, edits, removals and paid/unpaid answers are explicit participant actions, audited as `bill.created`, `bill.updated`, `bill.removed`, `bill.paid` and `bill.unpaid` with the amount before and after. Members who can only read see no change buttons. Mia's action types do not include bills; Mia bill drafts are deferred.

## Forecast rules

Round 3 (re-check findings 1–4) changed four rules: month-end balances, the estimate caveat, debt minimums from a midmonth balance, and what a sinking category counts. Round 2's rules stay otherwise.

Round 2 (review findings 1, 2, 5, 6 and the current-month note), as amended in round 3:

- **Opening cash.** Checking, savings and cash balances, all known and all dated the same day, in the current month or on the last day of the month before. Balances from different days, an earlier month, or with any unknown balance leave ending cash unknown and say why ("Your cash balances are from September 30. Update them in My Money to see ending cash.").
- **Month-end balance (round 3).** A balance dated the last day of the current month already includes all of that month, so the month adds nothing more: the forecast starts with the next month, and a past one-time bill still waiting for "Was this paid?" counts there. On December 31 of the plan year there is no next month, so December shows with no income or costs except an unanswered bill.
- **From a midmonth balance** (for example November 14), the rest of that month counts only what comes after that day:
  - Income: the month's plan minus income approved through that day, when approved statements cover every one of those days for every deposit account. Otherwise income is estimated by spreading the month's recurring pay over the days left, plus one-time income dated after the balance, and labelled as an estimate. Income schedules have no pay dates, so `IncomeTimeline.period_cents` with a date range returns a whole month of recurring pay; using it directly would count a paycheck already in the balance a second time.
  - Spending: for each category, the larger of what is left of the plan (plan minus spending recorded up to the balance date), its bills due after that date, and spending recorded after that date. Spending after the balance date is read the way Budget counts it (splits, minus refunds, with cash withdrawals moved to the purchases they paid for), so the balance never pays for the same purchase twice.
  - Debt minimums count in full, because their due dates are not saved (round 3 lead decision until plan item 2.4 adds them). The month is marked as resting on an estimate: "debt payments that may already be paid this month". No debt has a due-date field yet, so nothing narrower is possible.
  - Pay spread over the days left is an estimate in another way too: when statements don't cover the days before the balance, a paycheck that already landed in the balance can be partly added again. That is why the month says it rests on "estimated pay for the rest of this month" (round 3).
- **Planned yearly costs and the surprise fund** (the `sinking_expected` and `sinking_unexpected` groups; round 3 lead decision): set-asides move to her own savings, which is already counted as cash, so they are not money leaving the household. Saved bills count when they are due. The part of the monthly plan those bills don't cover still counts every month: uncovered = max(0, monthly plan − the category's saved bills over the 12 months from the forecast's first month ÷ 12). A past one-time bill still waiting for an answer counts toward the bills. With no saved bill, the whole plan counts. In round 2 one saved bill dropped the whole plan, so a "Car" plan covering registration, insurance and repairs lost insurance and repairs once the registration was saved.
- **Other categories** count the larger of the plan and their bills due that month. In the current month, spending already recorded counts when it is larger than the plan.
- **Income in the current month** is the larger of income approved so far and the plan; the "approved so far" figure is shown. A complete past month would use approved income.
- **One-time bills.** A bill she marks paid never counts again. A one-time bill whose date has passed and that is not marked paid appears once, in the current month, as "Was this paid?" and counts until she answers. She can undo with "Not paid after all".
- Bills outside every category add to planned costs. A month whose costs are well above her usual month is marked "Higher costs than usual" (the same threshold the old outlook used: at least $100 or 10% above the median month).
- **Estimates (round 3).** Each month lists what it estimates: "estimated pay for the rest of this month", "estimated bill amounts" (a bill marked as an estimate), and "debt payments that may already be paid this month". The forecast collects them through the first short month, or through December when none runs short. Home, Budget and Mia then say "This rests on estimates: …", including with "No month runs short through December".
- The first month that ends below zero is the short month. Named costs are contributors, not a claim that one cost is the sole cause. This is a month-end planning forecast, not an intramonth overdraft prediction or today's spendable cash.

## Where it shows

- **Home** shows one glance: the first short month and its costs, or "No month runs short through December" with December's ending cash, or what is still unknown, plus months with higher costs. "See every month and your bills" opens Budget with the forecast expanded and focused. The old grouped outlook was removed; the demo plan now sends a `year_forecast` too, so no screen renders the old path.
- **Budget → Year ahead and bills** has the month table, the plain "How this forecast works" list, and the bills editor. Saving, removing or answering "Was this paid?" refetches the plan in place: sections stay open, focus returns to Add bill, and the page does not reload. A refused save keeps what she typed. The remove confirmation sits beside its bill with focus on it. On a phone each month stacks as labelled rows, so nothing scrolls sideways.
- **Mia** answers only plain forecast and saved-bill questions. A worry, a payment report or a request for help choosing what to pay goes to the answers built for those ("We're short on rent this year, what do I do?", "Paid through December 15", "Paid $120 power, bills due scare me"). "Next big bill" means the largest saved bill due in the next 60 days (the one to get ready for); with nothing that soon, the next saved bill within 12 months. "What's due this month?" lists every bill. A month already past this year means the coming one, named with its year ("January 2027"). The search looks 12 months ahead across the year boundary. The year answer says when the short month includes estimates and no longer appends the technical rule. The plan is read once per message.

## Hand checks

Round 3, automated (`api/test/services/year_forecast_test.rb`, `year_forecast_answer_test.rb`; every new or changed test fails against round 2's code):

- **Month-end balance:** $1,000 dated November 30, today November 30, $200 pay, $100 utilities plan, $45 debt, and a $20 one-time fee from November 5 not yet answered. The forecast is December only: $1,000 + $200 − ($100 + $45 + $20) = $1,035. Round 2 re-applied November to the balance. Dated December 31: December has $0 in and only the $20 fee out, ending at $980.
- **Car:** $250 a month (registration $125 + insurance $75 + repairs $50), with only the $1,500 yearly registration saved, due March 10. $1,500 ÷ 12 = $125 covered, so $125 a month still counts. January $1,000 + $200 − ($100 + $125) = $975, February $950, March −$575 (adds $1,500). The year's costs are 12 × $225 + $1,500. Round 2 counted only $100 a month and January ended at $1,100.
- **Surprise fund:** $100 a month and one saved $690 repair in September. $690 ÷ 12 = $57.50 covered, so $42.50 still counts every month, including after the repair: $142.50 a month, $832.50 in September. December ends at $1,000 + 12 × $200 − 12 × $142.50 − $690 = $1,000.
- **The $1,500 registration** with a $125 plan is unchanged: $1,500 ÷ 12 = $125 covered and $0 uncovered, so January–April still end at $1,100 / $1,200 / −$200 / −$100.
- **Debt from a midmonth balance:** $1,000 on January 15, $200 pay without statements ($103.22 estimated), $30 already spent, so $70 of the plan is left and the $80 power bill (marked as an estimate) counts instead, plus $45 debt. January ends at $978.22 with the reasons "estimated pay for the rest of this month", "estimated bill amounts" and "debt payments that may already be paid this month"; February has only "estimated bill amounts". December ends at $978.22 + 11 × $55 = $1,583.22. Mia: "No month runs short through December in this plan; December would end with about $1,583.22. This rests on estimates: estimated pay for the rest of this month, estimated bill amounts, and debt payments that may already be paid this month. Starting from your cash balances on January 15."

Round 2, automated:

- $1,000 opening + $200 income − $100 category plan = $1,100 in January, $1,200 in February. A linked $80 power bill does not add another $80. March adds a $1,500 one-time registration: −$200.
- **Registration with a set-aside:** $125 a month set aside in a planned-yearly-cost category and a linked $1,500 yearly bill due March 10. January $1,100, February $1,200, March −$200, April −$100. The year's costs are 12 × $100 + $1,500, not $125 × 11 + $1,500. With the bill removed, January's costs are $225 again.
- **Midmonth:** $1,000 dated January 15, $200 monthly pay, no statements: $200 × 16/31 = $103.22 estimated; utilities $100 − $30 spent leaves $70, below the $80 power bill due January 31, so $80 counts. January ends at $1,023.22, February $1,123.22.
- **Partial income:** $50 approved so far against a $200 plan counts $200; $300 approved counts $300.
- **Paid one-time bill:** a $300 repair due December 20 counts once in January ("Was this paid?"), never in February; marked paid, it no longer counts.
- Talun manifest: $100 opening, $180 income and $100 planned monthly, $186.45 power arrears May 7 and $690 repair September 22. May ends at $313.55; September is the first short month at −$56.45, naming the repair.

Browser, round 3 (fictional local replay, production build, ports 3436/5436, November 21, 2026; same setup as round 2: $3,200 cash dated November 14, $5,400 monthly pay, $4,300 category plan including a $250 planned-yearly-cost set-aside, $90 debt minimums):

- Before bills: November $1,690 and December $2,700, as in round 2. Home, Budget and Mia now add "This rests on estimates: estimated pay for the rest of this month and debt payments that may already be paid this month."
- Car registration, $1,500 every year from December 10, in the planned-yearly-cost category (saved through the form): $1,500 ÷ 12 = $125 of the $250 plan is covered and $125 still counts. November $4,390 − $250 + $125 = $4,265 out, ending $1,815. December $4,265 + $1,500 = $5,765 out, ending $1,450.
- Talun repair, $690, one time, November 5, "Not in any category plan": November $4,955 out, ending $1,125; December $760; "Was this paid?" shown once.
- "Yes, it was paid": back to $1,815 and $1,450.
- Mia, phone: "Will we make it through the year?" gave "No month runs short through December in this plan; December would end with about $1,450. This rests on estimates: estimated pay for the rest of this month and debt payments that may already be paid this month. Starting from your cash balances on November 14."

Browser, round 2 (same setup; superseded where round 3 changed the sinking rule):

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

Round 3 re-took all five screenshots (390×844 and 1440×900, Chromium): the Home summary and Mia now show the estimate caveat, and the forecast shows round 3's numbers. The round 2 rows above are kept as the record of that round.

Evidence: [Home summary on phone](evidence/bills-forecast/phone-home-summary.png), [phone forecast](evidence/bills-forecast/phone-forecast.png), ["Was this paid?" on phone](evidence/bills-forecast/phone-was-this-paid.png), [desktop forecast](evidence/bills-forecast/desktop-forecast.png), [Mia on phone](evidence/bills-forecast/phone-mia.png). Chromium viewport testing, not Safari or a physical phone. No production deployment was requested.

Not covered in the browser: a midmonth balance with approved statements through the balance date (unit-tested with a stubbed reader; the coverage check reuses `ActualIncome`'s own statement-coverage rules), and a read-only member in a real session (no seeded read-only household).

Validation and cleanup results are recorded in the PR and final report. The lead owns review and merge; this worker does not merge.
