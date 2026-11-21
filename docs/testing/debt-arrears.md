# Debts with arrears: due day and past-due amount

Plan item 2.4. Fictional data only (the Talun household; a car loan $1,500 behind and a current store card).

## What changed

- `debts.due_day` (1–31, optional) and `debts.past_due_cents` (0 or more, optional). Both are NULL until she enters them. A blank past-due amount means "not entered" and is never shown or counted as $0 behind; 0 means she says she is caught up. Database check constraints back the model validations.
- A past-due amount is part of the balance, owed now. It is not added to the balance or to monthly debt payments.
- My Money → Debt: two new fields on the debt form, and the debt row shows "due on the 15th" and "$1,500 past due" (danger colour, red dot).
- Home → Needs you lists each debt she is behind on first ("Car loan: $1,500 past due · next payment due on the 15th"); the row opens Debt.
- Mia
  - Reviewed edits: Mia's existing debt review card now carries `past_due` and `due_day`. Nothing saves until she applies the card. The resolver accepts a past-due amount only when she wrote it next to "past due", "behind", "overdue" or "arrears", and a due day only when she wrote that day next to "due".
  - "What should I pay first?" with a past-due debt: catch up first, keep essentials and every other minimum current, then the program's payoff order (snowball/avalanche, #354) for anything extra.
  - Debt plan: step 1 is the catch-up; extra principal comes from the surplus left after the catch-up, and the cap on a target debt allows for its catch-up payment. If the catch-up is bigger than the month's surplus, extra principal waits.
  - Mia's context gets each debt's `due_day` and `past_due` plus a `past_due` rule; `due_date` stays in `unavailable_fields` while any debt has no due day.
- Statement-balance offers (#359) do not touch either field.

## Hand checks (Talun fixture)

Income $5,200; essentials $3,000; minimums $310 + $35 = $345; surplus $1,855.

| Case | Expected | Test |
| --- | --- | --- |
| Car loan $1,500 past due, snowball order | Step 1 catches up $1,500; $1,855 − $1,500 = $355 left; Store card cap $640 − $35 = $605, so "up to $355" | `household_finance_debt_arrears_test.rb` |
| Car loan $2,500 past due | $2,500 > $1,855 surplus, so extra principal waits | same |
| Past-due amount cleared | Unknown again (NULL), not $0; no Home row; ordinary bill answer | same |

## Not in this PR

#360 (bills and year forecast) and #362 (CFO Filter) had not merged when this branch was cut, so these parts wait for them:

- Forecast: count a debt minimum in the month by its due day (from a midmonth balance, only when the due day is after the balance date, and drop the "may already be paid" flag for debts with a due day); count a past-due amount once, in the first month, labelled as owed now.
- Past-due utility bills: a utility is a bill, not a debt. The simplest correct model is an optional past-due amount on the #360 bill record (owed now, counted once in the first forecast month), not a debt record and not a second one-time bill.
- CFO Filter: treat past-due amounts as consumer debt that is due now.

## Browser evidence (local stack, `LOCAL_STACK_REPLAY=1`, ports 3436/5436)

Entered $1,500 past due and due day 15 on the Car loan through the form, then checked Home, My Money and Mia.

- Phone 390×844: [debt card](evidence/debt-arrears/phone-debt-card.png), [Home](evidence/debt-arrears/phone-home-needs-you.png), [Mia "What should I pay first?"](evidence/debt-arrears/phone-mia-pay-first.png)
- Desktop 1440×900: [Home](evidence/debt-arrears/desktop-home-needs-you.png), [debt card](evidence/debt-arrears/desktop-debt-card.png)

The phone check found the past-due line overlapping the details line; fixed in `moneyProfile.css` and checked again.
