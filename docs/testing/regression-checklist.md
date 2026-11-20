# Regression checklist

Run this before each phase gate in the build plan, and after any release that touches money. "Touches money" means a change under `api/app/services/financial_documents/`, `api/app/services/household_finance/`, `api/app/services/spending_patterns/`, `api/lib/scorecard/`, or the web screens for Statements, Budget, Home and Mia's statement or purchase cards.

Two parts: an automated pass on the local full stack, and a short pass on production with a fictional test household.

## 1. Automated, on the local full stack (about a minute)

`reset` drops this checkout's local-stack database and deletes its uploads and mail. Save anything you want to keep first.

```bash
bin/local-stack reset
bin/local-stack up
bin/local-stack run bin/rails local_stack:household
cd web && npm run test:local-stack
```

It uses the real API with nothing mocked, and fails if the browser sends any request off this machine. It covers:

| ID | What it proves | Widths |
|---|---|---|
| A1 | A fictional bank CSV, reviewed by hand (coverage, account type, own-account transfer, cash withdrawal category, card payment, refund), saves every line. Budget's August 2026 spending is exactly the posted spending, $2,339.65, less the $12.99 refund that goes back to the Amazon purchase's category: $2,326.66. | Review at 1366 only |
| A2 | The saved statement and that August spending read the same on a phone. | 390 (WebKit), 320 |
| A3 | Go live starts with no group ticked, and only the ticked group gets the program's voice (read back through the API). | 1366 |
| A4 | The groups list on a phone. | 390 (WebKit), 320 |
| A5 | Budget's year arrows stay on the month row, and Budget, Statements and Groups don't scroll sideways. | 390 (WebKit), 320 |

The suite assumes a fresh stack; the statement test stops at once if the participant already has uploads. The review flow itself runs only at desktop width; reviewing a statement at phone width is checked by hand (M9).

## 2. By hand, on the local full stack

Use the fictional people `bin/local-stack status` lists. Check each at 1366, 390 and 320, and check saved results through the API or the screen that reads them, not only the confirmation message. M1 and M7 need the state before any setup: run them on a freshly reset stack (`reset`, then `up`, without `local_stack:household` and before the automated pass), and reset again between widths.

| ID | Scenario | Expected saved result |
|---|---|---|
| M1 | Set up a household by chatting with Mia: income "a month, paid twice a month", two bills, a family loan that is behind, a one-time medical bill, a savings goal. | Income stays monthly, not doubled; the loan is saved as a debt and the medical bill as a one-time bill; names keep their capitals. Needs a model key (see local-stack.md). |
| M2 | Upload a statement whose lines overlap a CSV of the same account (one line dated a day apart). | The copy is asked about as "Same charge?"; approving both is refused until she answers. |
| M3 | Save a purchase with "No category yet", then pick a category from the list. | It stays listed as "What was this for?" until she picks one; her corrected amount and name are kept. |
| M4 | Answer "Something's missing", then change it from Statements and from Mia's card. | The answer can be changed in both places; the statement stays unfinished until it is "Nothing's missing". |
| M5 | Log a purchase that matches one she already has (receipt, chat or check-in). | She is asked "Same purchase?"; "Same purchase" leaves one purchase. |
| M6 | Ask Mia "What should I cut first?" and "Where is my money going?" with medical and family-support spending present. | No suggestion to cut medical, childcare or family support; no one-off payment offered as a monthly saving; store names are clean. Needs a model key. |
| M7 | Admin with no program creates a group; admin with one program opens Groups and Coaching. | No program: offered "Start a program". One program: starts inside it, no picker step. |
| M8 | Join a savings challenge with an invite code, check in "How was today?", set a goal and an amount set aside, reload. | The day, goal and amount set aside are kept; the coach sees check-ins but no amounts. |
| M9 | At 390 and 320, upload the fictional CSV from A1 and answer each kind of question (coverage, account type, own-account transfer, cash category, card payment, refund), then approve the rest. | Every control is reachable without sideways scrolling; the saved result is the same as A1 ($2,326.66 for August 2026). |

## 3. On production, after a release that touches money

Use Leon Admin's own test household only: never Mrs. Mel's, Bethany's or the BOG pilot's. Use fictional or Leon's own data, and remove any test group or person afterwards, the way the round 8 and round 9 purge scripts did.

| ID | Check |
|---|---|
| P1 | The release is live: the Render deploy shows the merge commit and `/up` answers 200; for a web change, Netlify's production deploy shows the merge commit. |
| P2 | A read-only Rails check (over `render ssh`) of the specific behaviour the release changed, on Leon Admin's household. Print counts and booleans only, never amounts or store names. |
| P3 | One of the manual scenarios above that the release touched, in the browser, at phone width. |
| P4 | Home, Budget and Mia agree on this month's spending for Leon Admin's household. |

Record each run in the PR or the plan: commit tested, environment, which IDs passed, failed or weren't run, and why.
