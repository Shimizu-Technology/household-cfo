# Debts with arrears: due day and past-due amount

Plan item 2.4. Fictional data only (the Talun household; a car loan $1,500 behind and a current store card).

## What changed

- `debts.due_day` (1–31, optional) and `debts.past_due_cents` (0 or more, optional). Both are NULL until she enters them. A blank past-due amount means "not entered" and is never shown or counted as $0 behind; 0 means she says she is caught up. Database check constraints back the model validations.
- A past-due amount is part of the balance, owed now. It is not added to the balance or to monthly debt payments.
- My Money → Debt: two new fields on the debt form, and the debt row shows "due on the 15th" and "$1,500 past due" (danger colour, red dot).
- Home → Needs you lists each debt she is behind on first ("Car loan: $1,500 past due · next payment due on the 15th"); the row opens Debt.
- Mia
  - Reviewed edits: Mia's existing debt review card now carries `past_due` and `due_day`. Nothing saves until she applies the card.
  - Grounding: a past-due amount must be what she says she owes now on that debt, next to "past due", "behind", "overdue" or "arrears". A date ("past due on 11/15"), another debt's arrears, or arrears she has caught up ("I was $100 behind, but I caught up") is refused. A due day must be a recurring day of the month ("due on the 15th", "the 15th of each month", "due day is 15"); a dollar amount ("the minimum due is $25") or a one-off date ("due on November 15") is refused. When a value is refused, Mia asks about that field (due day, past due, APR, balance or minimum).
  - Clearing: "unknown" clears a field only when that item's own words say so. In a write plan each item is checked against its exact source span, so "Rename Visa to Travel Card and rename Amex to Blue Card" never clears either card's past-due amount or due day.
  - "What should I pay first?" with a past-due debt: catch up first, keep essentials and every other minimum current, then the program's payoff order (snowball/avalanche, #354) for anything extra.
  - Debt plan: the catch-up is worked out once. Each debt's catch-up is min(past due, balance). Ranking, payoff caps and the monthly and windfall answers all use the balance left after it, and the cash left after it. A debt the catch-up pays off is never the extra-principal target, and its minimum isn't counted on top. A refund or bonus covers whatever catch-up the monthly surplus can't before any principal.
  - Records that conflict: if a past-due amount is above its debt's balance (including a $0 balance and $0 minimum), or an approved $0 summary sits over an overdue debt, Mia never says "debt-free" or estimates a payoff. She names the conflict and asks her to fix the balance or the past-due amount. Home marks the row "more than its balance, check both".
  - Mia's context gets each debt's `due_day` and `past_due` plus a `past_due` rule. `due_date` (an exact next date) is always unavailable; `due_day` is unavailable while any debt lacks one or there are no canonical rows (summary mode).
- Statement-balance offers (#359) keep both fields. A statement balance below the past-due amount is kept as a visible conflict, not silently changed.
- My Money sends only the debt fields she changed, with the values her form showed (`expected`). If a field changed in another tab since (for example, a past-due amount applied from Mia), the server refuses the edit with 409 `changed_elsewhere` and the page reloads the latest details. An entered $0 past due shows "Caught up"; blank shows nothing.
- Mia debt cards prepared before this release still apply: optional fields that are blank are left out of the "before" snapshot and of the normalized create input, so old cards match. A field entered since still makes a card stale.

### CFO Filter and windfall split (#362)

- Card and loan arrears (never the mortgage), each capped at its balance, are a one-time catch-up. A spend must fit the year's surplus after the catch-up. In the payoff projection, cash left after the minimums catches up arrears before any extra avalanche principal, and unpaid arrears carry forward. The base surplus and emergency-fund target stay on the recurring baseline.
- Windfalls follow the program's order. Within the consumer-debt step, `consumer_debt_catch_up` comes first, then principal on what is left of the same balances. Known arrears are reported even when the total debt is unknown, and the rest waits on that unknown.

### Year forecast (#360)

- Debts tracked one by one with a due day count on that day; days 29 to 31 fall on a short month's last day. From a midmonth balance, only a payment due after the balance date counts. "May already be paid" is kept only for undated minimums and the summary total.
- Past-due amounts on debts count once, owed now, in the first forecast month (February when a January 31 balance moves the start). They are never above the balance, and later minimums stop once it is paid.
- Bills have an optional past-due amount (`bills.past_due_cents`, "Past due now" on the bill form). It counts once in the first month and never for a one-time bill she marked paid. It stays out of the sinking plan its bills cover. In its category it adds to the plan or the bill, and spending recorded this month counts toward the two together. Mia's "What's due this month?" lists dated debt payments and what is owed now.

## Hand checks (Talun fixture)

Income $5,200; essentials $3,000; minimums $310 + $35 = $345; surplus $1,855.

| Case | Expected | Test |
| --- | --- | --- |
| Car loan $1,500 past due, snowball order | Step 1 catches up $1,500; $1,855 − $1,500 = $355 left; Store card cap $640 − $35 = $605, so "up to $355" | `household_finance_debt_arrears_test.rb` |
| Car loan $2,500 past due | $2,500 > $1,855 surplus, so extra principal waits | same |
| Past-due amount cleared | Unknown again (NULL), not $0; no Home row; ordinary bill answer | same |

## Hand checks added in round 2

| Case | Expected | Test |
| --- | --- | --- |
| Visa $100 balance, all $100 past due, $25 minimum | Not a target; minimums shown $345 not $370; Store card "up to $255" ($1,830 − $1,600 catch-up + $25 not owed) | `household_finance_debt_arrears_test.rb` |
| −$3,145 surplus and a $50 refund | The whole $50 goes to the catch-up; $1,450 still past due; no principal target | same |
| Talun Telecom $120/month, $951.70 behind | First month +$951.70 once, then $120 | `year_forecast_test.rb` |
| Power in Utilities: $100 plan, $200 behind, $250 spent | $300, not $550; $350 spent counts $350 | same |

## Browser evidence from round 1 (local stack, `LOCAL_STACK_REPLAY=1`, ports 3436/5436)

Round 2 changes were checked with component and service tests only; no new browser pass.

Entered $1,500 past due and due day 15 on the Car loan through the form, then checked Home, My Money and Mia.

- Phone 390×844: [debt card](evidence/debt-arrears/phone-debt-card.png), [Home](evidence/debt-arrears/phone-home-needs-you.png), [Mia "What should I pay first?"](evidence/debt-arrears/phone-mia-pay-first.png)
- Desktop 1440×900: [Home](evidence/debt-arrears/desktop-home-needs-you.png), [debt card](evidence/debt-arrears/desktop-debt-card.png)

The phone check found the past-due line overlapping the details line; fixed in `moneyProfile.css` and checked again.
