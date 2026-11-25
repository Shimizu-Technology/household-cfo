# Cohort participant tools

Coach Studio lets an administrator or a coach assigned to a cohort choose which optional teaching tools participants can open. The server remains the source of truth for both navigation and endpoint access.

## Module policy

The following financial control surfaces are always enabled:

- Home
- Review
- Ask Mia
- Budget
- My Profile
- Wealth

The first coach-controlled modules are CFO Filter and Optionality. A coach cannot disable a core module through the API or the UI.

Existing cohorts receive a published version with both optional modules enabled when the migration runs. New cohorts begin with the core experience only. A participant without a cohort keeps the full standalone experience. A participant whose cohort configuration is missing, unpublished, or malformed receives the core experience only.

## Draft and publication lifecycle

Each cohort has one editable configuration and immutable published versions:

1. Save an optional-module draft. Every saved change increments its revision and invalidates the previous preview.
2. Preview that exact revision. The response shows the participant navigation for desktop and phone layouts.
3. Publish using the current draft revision, preview digest, and current published-version ID. These compare-and-set fields prevent one coach from overwriting another coach's work.
4. Restore an earlier version when needed. Restore creates a new immutable version and audit event; it does not modify history.

Draft, preview, publish, and restore are available to administrators and coaches assigned to the cohort. Completed and archived cohorts are read-only. Participants cannot access these endpoints.

## Method settings (schema 5)

Schema 5 adds a compact `method` block: Mrs. Mel's method as group settings. It goes live through the same draft, preview, publish and Go live steps as tools; there is no separate path. Release catalog 7 carries schema 4 and 5 experiences with the same tools as catalog 6. A schema 1–4 config or release reads as the defaults. Go live's upgrade-to-current step rewrites only a draft from before schema 4; a schema 4 draft becomes schema 5 when a coach edits it, so reviewing Go live never changes a draft that is open in the tools editor.

| Setting | Default | Where it applies |
| --- | --- | --- |
| `status` | A target is Green within 12 months at the current monthly surplus, Yellow within 36, Red beyond or never. Monthly surplus is Green from $1,000 and Yellow from $500. | `HouseholdFinance::ReadinessCalculator`; Home status; Mia's readiness answers and context |
| `emergency_fund_months` | 3 months of planned costs. A household's own runway goal (`goals.target_months`) wins. | `SnapshotBuilder` target; Home; Mia |
| `protected` | Housing, utilities, medical, childcare and school, debt minimums, family support. These are always protected; a program can only add groceries, giving (tithes and donations) or family & community. | `SpendingPatterns::Analyzer` category protection. Care and bill store names, money sent to people and insurance stay protected too. A config that drops a core item is rejected (422). |
| `priorities` | 1 Emergency fund · 2 Debt acceleration · 3 Wealth building · 4 Experiences and life | CFO Filter priority stack; Mia's debt-or-savings answer and context |
| `windfall` | Emergency fund gap, then consumer debt (not the mortgage), then surplus | CFO Filter; Mia's one-time money split (`HouseholdFinance::WindfallSplit`). Consumer debt is unknown when debts are one summary total (it may include a mortgage) unless that total is a confirmed $0, or when no debts are listed; the rest of the money then waits on the debt step and Mia asks for the cards and loans. |
| `income_split` | 50% emergency fund, 25% extra debt payments, 25% surplus | CFO Filter; Mia's raise or new-job answer, with the dollars worked out in Rails (`HouseholdFinance::IncomeSplit`) |
| `group_names` | `plain`: Must-pay bills, Flexible spending, Planned yearly costs, Surprise fund. `method`: Non-discretionary, Discretionary, Sinking Fund — Expected, Sinking Fund — Unexpected. | Labels only (`HouseholdFinance::ExpenseGroups`): Budget groups, every `stack_label`, the category group pickers, Mia's context and her answers that name a group. Categories, stack keys and totals never change. |
| `home_view` | `month`: this month first, the year outlook just below. `year` puts the year outlook first. | Home order. Each person can switch for themselves (`PATCH /api/v1/home_view`, saved on `household_memberships.home_view`); her saved choice wins over the program's, and `null` goes back to it. `workspace.home_view` reports `program`, `chosen` and `effective`. |
| `challenge` | `length_days` 90, `checkpoints` `"thirds"` (Day 30, 60 and 90), `suggested_goal_cents` 50,000 ($500), `counts` `savings`: new money set aside counts; extra debt payments are tracked alongside but not counted. A coach can set 30–180 days, thirds or 1–6 increasing days ending on the last day, a whole-dollar suggestion from $100 to $5,000, and `savings_and_debt` (extra payments on a card or loan beyond the minimum also count). | `SavingsChallenge::Rules`. Each enrollment records the rules of the offer she accepted and keeps them (a database guard freezes them); only new enrollments read the live release. Applies to the calendar and timeline, checkpoints and their final review, the reminder window (her `ends_on`), the coach roster (each row's own day and length; the group's live rules on top), sponsor reports (every check-in day on the live schedule or on a schedule someone joined under, plus any sealed day, sealable in any order; a person is counted on her own days and is the `other_schedule` band on any other; `custom_target` compares with her own suggestion; the report states the counting rule behind at target), Go live review (it warns when a schedule change leaves people on more than one schedule), the join offer, the participant challenge screens, Go live review lines and Mia's challenge answers and goal proposals. |
| `debt_order` | `both`: snowball and avalanche side by side, each with its own Rails-computed cap, and she chooses. `snowball` or `avalanche` leads with that order and still names the other. | `HouseholdFinance::DebtStrategyPlanner` (Mia's debt-order answers); Mia's context. Minimums always come first; the numbers are the same whichever order leads. |

`group_names`, `home_view`, `debt_order` and `challenge` came later in schema 5 and are optional: a block without them reads as their defaults, and its normalized bytes and digest do not change, so sealed releases keep their evidence. The tools editor saves all four once a coach edits the method.

`CohortExperience::MethodSettings` validates the block. In a request, a household's method is the signed-in caller's program, resolved once and reused for the rest of the request. Without a caller it is the asking member's or the owner's (then a partner's) program, never a coach viewer's. Any fault reads as the defaults. Readiness is the emergency fund target's colour, computed on the whole surplus. Safe-to-spend is 40% of a positive surplus outside Red, capped so that spending it still keeps the colour shown (the rest of the surplus still reaches the target inside that colour's months). The method adds under 1 KB to a release's 16 KB experience snapshot.

## Participant enforcement

`GET /api/v1/workspace` includes `workspace.capabilities`, resolved from the same effective cohort membership used for the Mia persona. The web app builds participant navigation only after that response arrives.

When an optional module is disabled:

- its payload is omitted from the workspace response;
- its direct API endpoint returns `403` with `code: "module_disabled"`;
- Mia's context states which product modules are available;
- its navigation link is absent; and
- a saved hash link redirects to Home and focuses a visible live-region explanation.

The browser check is a usability measure. The API check is the authorization boundary.

## API endpoints

All paths below are under `/api/v1/admin/cohorts/:cohort_id`:

- `GET /experience_configuration`
- `PATCH /experience_configuration`
- `POST /experience_configuration/preview`
- `POST /experience_configuration/publish`
- `GET /experience_configuration/versions/:id`
- `POST /experience_configuration/versions/:id/rollback`

The patch body includes `experience_configuration.draft_revision` and `draft_config`. Publish also requires the preview digest and expected published-version ID. Rollback requires the current draft revision and expected published-version ID.

## Operational checks

After deployment:

1. Confirm the migration created one published version for every pre-existing cohort.
2. Open Coach Studio as an assigned coach and verify only manageable cohorts appear.
3. Publish a draft with one optional module disabled in a non-production test cohort.
4. Sign in as its participant and verify navigation, direct hash handling, workspace payload omission, direct endpoint denial, and Mia module awareness.
5. Restore the prior version and confirm the module returns after the participant refreshes.
