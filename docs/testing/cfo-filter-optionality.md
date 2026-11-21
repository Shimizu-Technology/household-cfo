# CFO Filter and Optionality implementation brief

November 21, 2026. Base: `add758793ff92dd16299583496088032a97e4bb7`.
Worktree: `/Users/agent/work/household-cfo`; branch: `feat/cfo-filter-optionality`.

Participants use these program-controlled tools to compare possibilities before reviewing any financial change. Coaches control access through published program tool settings. The source contracts are `SnapshotBuilder`, `IncomeTimeline`, `MethodSettings`, `WindfallSplit`, and `SpendingPatterns::Analyzer`. Existing setup and missing-balance flags remain authoritative. No paid services or live model calls are needed.

## Required source still missing

`docs/HouseholdCFO/household_cfo_v4.html` is absent from the supplied checkout and tracked main. The worker requested it during implementation. **Prototype sample-number comparison remains blocked. This is a draft implementation for lead review, not completed prototype acceptance.** No prototype constants or sample results have been invented.

## Calculation contract and hand checks

- Base surplus is recurring monthly income, excluding bonus-type sources and one-time income, less planned category costs and required debt minimums. Example: $5,400 minus $4,390 = $1,010, even with a separate $2,000 bonus.
- Spend comparison subtracts the proposed purchase from this month's base surplus, leaving savings unchanged. Emergency target gap is planned costs times the household's approved runway target (otherwise the program emergency-fund months), less known liquid balances, floored at zero. At $4,000 costs, a three-month target and $0 savings, gap is $12,000. $1,000 surplus reaches it in 12 months (green); $500 remaining after a purchase gives a 24-month pace (yellow). **The displayed pace assumes that remaining surplus each month. It is not a forecast of a one-time purchase's future cash flow.** Source verification must confirm this interpretation with the prototype.
- Flip targets independently use the full surplus. Required monthly surplus is `ceil(gap / colour months)` in cents; total income is costs plus that surplus; additional income is the positive difference from current surplus. $12,000 gap needs $333.34/month for 36 months or $1,000/month for 12 months. Monthly-surplus thresholds come directly from program settings.
- The debt light is explicitly a principal-only **consumer debt** comparison excluding mortgage. $6,000 / $1,000 = six months, green. It excludes interest, fees and minimum-payment acceleration and must not be represented as an amortized lender payoff quote. Lead review should confirm this scope against the missing prototype before approval.
- Windfalls reuse `WindfallSplit` and the program's order. $20,000.01 fills a $12,000 emergency gap, then $6,000 consumer debt, then leaves $2,000.01 surplus. An unknown step holds the remaining money there instead of skipping it.
- Optionality gap is `max(costs - replacement income, 0)` and is calculated before the draw defaults. Replacement income includes current business income and approved continuing income; an absent, unconfirmed business-income amount is unknown, not $0.
- With effective monthly growth `r = 1.05^(1/12) - 1`, monthly balance is `previous balance * (1+r) - draw`. Runway counts fully funded months; if growth covers the draw, savings do not run out in this model. $60,000 savings and $3,000 draw fund 20 months: $2,702.86 remains after month 20, while month 21 would be short $286.12. Green is 36+, yellow 18–35, red below 18. This is an uncertain growth assumption, not a guaranteed return.

## Four reported prototype bugs

1. Debt can be green within the program's green-month threshold, including confirmed zero debt.
2. Base surplus excludes both scheduled one-time income and bonus-type sources.
3. Optionality computes the gap before prefilling the draw. An explicit $0 draw remains $0.
4. Both tools and the added deterministic Mia explanations read the same Rails facts. Scenario overrides are request-local. They never save or approve financial changes; they also suppress normal missing-plan initialization.

## Agent-executed affected-flow QA

Fictional Talun fixture; offline local stack with `LOCAL_STACK_REPLAY=1`, API 3426 and web 5426. Required dimensions are Chromium at 390×844 and 1440×900. Native mobile hardware, Safari/WebKit and production are not covered. The Mac mini does not support WebKit startup.

1. CFO spend: enter $100 against Talun's $1,010 base surplus; expect $910, updated target pace and surplus colour. Windfall calculation must preserve that spend result.
2. Flip light: show all three independent targets, unknown-aware yellow/green surplus, total income and extra-income requirements.
3. Windfall: enter $1,000; expect the emergency gap step to receive $1,000.
4. Optionality: known $0 business income permits the initial $4,390 draw. Explore $60,000 savings, $4,000 costs and $1,000 replacement income using gap-derived draw; expect 20 fully funded months and yellow. Reload must restore approved $3,200 savings.
5. At both widths: no horizontal overflow or browser errors. Buttons stack full width. The results stay still and use live regions; no added motion.

Run from repository root: `node web/scripts/check-finance-scenarios.mjs`, while the offline stack is running. Screenshots live under `docs/testing/evidence/cfo-filter-optionality/`. All five scenarios passed at both required Chromium sizes on the implementation content committed with this brief (screenshots refreshed after the unknown-business-income fix). The final PR/report records the head, automated counts and gate status. Screenshots alone do not establish acceptance.

## Review and remaining work

The lead reviews and merges. Obtain the original prototype, compare its correct sample calculations, resolve the spend/debt/growth interpretation above, and rerun affected tests and browser scenarios for any changes. No edit to `api/config/mia_personas.yml`. Netlify deploy previews remain off. A production web build is expected if this UI change is later merged.
