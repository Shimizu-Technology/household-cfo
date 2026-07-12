# Annual planning correctness

Updated: 2026-07-12

Mrs. Mel's annual-planning requirement is that stable income repeats forward until the household changes it. A future change must affect future months without rewriting prior months. One-time income must land only in its real month.

## Income timeline model

`income_sources` remain the approved profile-level base facts. `income_schedule_entries` add versioned annual-plan events:

- `recurring_change`: becomes effective at the beginning of a month and continues until the next recurring change for that source. A zero-dollar recurring change ends the income.
- `one_time`: adds the approved amount only to its effective month, for bonuses or other isolated income.

For every budget month Rails:

1. finds the latest recurring change effective by the end of that month,
2. falls back to the income source's base amount when no change exists,
3. converts the active cadence into a monthly amount,
4. adds one-time entries in that month,
5. sums all active household income sources.

The timeline is household-scoped, month-normalized, and range-bounded. A source can have only one recurring change in a month, while multiple labelled one-time entries can coexist. The annual plan API returns the source timeline beside the 12 computed monthly totals so the UI can explain exactly why a month changed. Home, readiness, and Mia's current approved snapshot use the recurring amount effective in the current month. One-time income appears in annual cash flow without inflating the recurring readiness baseline.

## Annual outlook

Rails also returns a deterministic annual outlook with:

- income, planned outflow, and baseline surplus for every month,
- the median planned month as the typical outflow,
- future months at least 10% and $100 above typical,
- the next month with an Expected Sinking Fund allocation and its leading categories.

This is planning guidance, not a new write path. Budget allocations and approved income facts remain the source of truth.

## Product boundary

This first implementation uses direct, explicit editing. Mia does not conversationally change income because income is a profile fact and requires a specialized supervised review flow separate from budget-allocation action drafts.
