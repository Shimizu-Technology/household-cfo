# Household CFO product/design brief

Updated: 2026-06-30

V1 feedback update: Mrs. Mel clarified that the participant is the Household CFO and Mia is the AI coach/assistant. The visual direction should move away from heavy green toward warmer neutrals, dusty rose/deep mauve, terracotta, and sage while keeping red/yellow/green primarily for status.

Sources reviewed:

- Mrs. Mel's original prototype: `/Users/jerry/.hermes/cache/documents/householdcfo_review/HouseholdCFO/household_cfo_v4.html`
- Raw meeting transcript: `/Users/jerry/clawd/obsidian-vault/work/shimizu-tech/Mel-Mendiola-ASC-Trust/16) Meeting to go over Personal Finance Coach.md`
- Meeting synthesis: `/Users/jerry/clawd/obsidian-vault/work/shimizu-tech/Mel-Mendiola-ASC-Trust/17) Meeting synthesis - Vera personal finance coach and BOG connection - 2026-06-17.md`
- Shared-drive review: `/Users/jerry/clawd/obsidian-vault/work/shimizu-tech/Mel-Mendiola-ASC-Trust/18) Household CFO shared drive review - 2026-06-18.md`
- Design/process skills: `react-product-projects`, `claude-design`, `popular-web-designs` with Intercom-inspired warm clean UI vocabulary.

## Product intent

Household CFO is the first consumer-facing skin on top of VERA infrastructure.

VERA should stay invisible to end users. Household CFO is the brand users experience. Mia is the AI coach inside Household CFO.

The first product should feel like:

- a calm financial coach,
- a household operating system,
- a cohort tool for women/breadwinners/co-breadwinners,
- a culturally aware coaching experience,
- not a generic spreadsheet or robo-advisor.

## Mel's implementation vision from transcript

Key requirements:

- The app should reduce spreadsheet burden. Long term, users should not have to touch Excel.
- Users can start with manual input, but uploads/photos should eventually populate the budget.
- Inputs include budget spreadsheet, credit cards/debt, pay stubs, receipts, and bank/credit statements.
- The app should support cohorts, not just one-off personal use.
- Quarterly cohort model is likely.
- The June event and FinCon are credibility milestones.
- Mel wants a working model, not only slides.

Important quote-level ideas:

- It should have personality: a local/Chamorro-aware coach who can lovingly say, “slow down, why are you spending that much?”
- Mia should combine accountability/personality with financial literacy.
- The product should use culturally aware CBT: what happened, what it means, and one next move.
- The demographic is people who wake up and realize, “I need to get my stuff together, but I still have dreams.”

## Original prototype: visual system

Prototype title: **The Household CFO 2026**

Current palette:

- Cloud/cream: `#F0EEEE`, `#E6E3E3`, `#FBF9F7`
- Plum/maroon: `#4A2E35`, `#6B4450`, `#331F25`
- Emerald: `#0F4C3A`, `#1A6B52`, `#0A3328`
- Gold: `#D4AF37`, `#E2C55A`, `#B8962E`
- Charcoal: `#1F2421`
- Negative red: `#8B2020`

Typography:

- Headings/numeric emphasis: Cormorant Garamond
- Body/UI: Montserrat
- The contrast gives a premium advisor/editorial feeling.

Visual feel:

- Premium, local-finance-advisor-ish, feminine without being childish.
- Strong use of a narrow centered content column, even on desktop.
- Dashboard is data-rich and impressive, but can intimidate first-time users.
- Onboarding modal is warm and useful but should not block screenshot/demo flows unless intentionally shown.

Mel's own design feedback:

- She is getting tired of the purple/gold.
- She wants it cleaner, potentially black/white with selected colors.
- She likes red/green/yellow status-style signals.
- She wants to streamline and cut from the current front end, not add more complexity.

## Original prototype: functionality map

Prototype sections:

1. Onboarding
   - Mia intro.
   - Income: primary income, rental/passive income, bonus.
   - Expenses: housing, fixed bills, food/gas/discretionary.
   - Savings/debt: emergency fund, consumer debt, upload.

2. Home
   - Full-year income.
   - Spend.
   - Year-end cash.
   - Baseline gap.
   - Income by source chart.
   - Key assumptions.

3. Cash Flow / Baseline / Budget / Wealth
   - Monthly/projection views.
   - Net worth and liquid net worth.
   - Retirement projection.
   - These should likely collapse into a simpler **Budget** and **Wealth** flow.

4. Optionality
   - Monthly need.
   - Business income.
   - Savings runway.
   - Passive income.
   - Filler job.
   - Jump-readiness/dream-gap framing.

5. CFO Filter
   - Spend decision filter.
   - Income increase simulation.
   - One-time payment/windfall allocation.
   - Strategic targets and priority stack.

6. Ask Mia
   - Context-loaded assistant UI.
   - Quick question chips.
   - Upload affordance.
   - Disclaimer.
   - Strongest screenshot/marketing surface.

7. My Profile
   - Profile completeness.
   - Editable income/expenses/savings/debt.
   - Upload cards for Budget Spreadsheet, Bank/Credit Card Statement, Pay Stub.

## Desired navigation/order

From Mel's notes:

1. Home
2. Ask Mia
3. My Profile
4. Budget — Cash Flow and Baseline can move inside Budget
5. Wealth
6. CFO Filter
7. Optionality

For the next React pass, use this order. Avoid the current repo order where Dashboard is first and Cohort is visible as a main user tab.

Admin/cohort should be separated later as a coach/admin view, not part of the participant's first nav.

## Mia voice rules

Mia = Money Interactive Assistant.

Identity:

- young Chamorro woman,
- Household CFO coach,
- powered by VERA,
- direct, warm, culturally grounded, old soul,
- accountability with love.

Response rules:

- Validate before coaching.
- 3–5 sentences.
- Plain text, no markdown.
- CBT frame: what happened → what it means → one next move.
- Use `Chelu` sparingly.
- `Umbee gachong` only for repeat known-bad patterns, never to shame.
- `Lanya` only for genuinely surprising wins/misses.
- Never use `par` as friend.
- Avoid `just` and `simply`.
- Accountability applies to decisions/patterns, never a person's worth.

## Core framework/IP to surface

The Expense Stack:

1. Non-discretionary — fixed, non-negotiable expenses.
2. Discretionary — choices, dining, entertainment, subscriptions.
3. Sinking Fund — Expected — known irregular expenses: registration, back to school, holidays.
4. Sinking Fund — Unexpected — medical, car repair, life.

This is important because most budgeting tools collapse categories too much. Household CFO should help users stop being surprised by their own lives.

## UX principles for next implementation

Prioritize:

- mobile-first and thumb-friendly,
- clear next action on every screen,
- fewer tabs, stronger hierarchy,
- fast comprehension before detailed data,
- coach-like guidance next to numbers,
- progressive disclosure for complex calculators,
- demo-safe content,
- no generic SaaS filler.

Design posture:

- Use the prototype's warmth, serif/sans contrast, and financial-coach tone.
- Reduce heavy green/plum/gold dominance; move toward warm black/white/cream with dusty rose, deep mauve, terracotta, and sage.
- Use Intercom-inspired warm clean surfaces: warm canvas, clear text, simple borders, restrained accent.
- Keep Mia visually distinct with the warm mauve/terracotta mark, not a masculine green identity.
- Use red/yellow/green for status/readiness only, not decoration.

## Immediate frontend changes recommended

1. Reorder nav to:
   - Home
   - Ask Mia
   - My Profile
   - Budget
   - Wealth
   - CFO Filter
   - Optionality

2. Convert **Dashboard** to **Home**:
   - show a calm top-level snapshot,
   - include a clear `Ask Mia what this means` path,
   - avoid overwhelming all metrics at once.

3. Upgrade **Ask Mia**:
   - closer to the original prototype: hero card, quick chips, context loaded status, upload affordance, disclaimer.
   - enforce Mia voice in seed content and API prompt.

4. Upgrade **My Profile**:
   - add profile completeness,
   - sections for Income, Expenses, Savings & Debt,
   - upload cards for spreadsheet, statement, pay stub,
   - manual-entry fallback.

5. Add **Budget**:
   - merge cash flow/baseline/budget into one screen,
   - introduce Expense Stack categories.

6. Add **Wealth**:
   - show net worth/liquid net worth/longer-term progress in a simpler non-intimidating way.

7. Refine **CFO Filter** and **Optionality**:
   - keep them powerful but guided,
   - use plain-language explanations and one decision at a time.

## Defer

- real OCR/document parsing,
- Stripe/Worldpay/PayPal,
- SMS/WhatsApp,
- full auth hardening,
- true multi-skin white-label system,
- financial advice beyond education/coaching boundaries.

## Acceptance criteria for next frontend pass

- React app reflects Mel's intended nav/order.
- Core screens are understandable on phone-width and desktop-width.
- Home, Ask Mia, My Profile, Budget, CFO Filter, and Optionality are screenshot-worthy.
- Mia copy follows the persona rules.
- App still builds with `npm run build`.
- Rails tests still pass.
- New screenshot pack generated from the real app.
