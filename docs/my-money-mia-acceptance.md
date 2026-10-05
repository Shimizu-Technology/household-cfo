# My Money and Mia acceptance

The participant should be able to find a financial record by its topic, read the
same approved facts through Mia, and review a proposed edit before applying it.
BOG's daily workflow remains Today, Savings, Mia, and Statements. Full household
planning is available through My Money without becoming a challenge prerequisite.

## Records and scope

| Topic | Manual destination | Mia reads and reviewed edits | Separate facts |
| --- | --- | --- | --- |
| Income | My Money → Income | Saved sources, effective amounts, schedules; add, edit, end, restore sources and schedule changes | Modeled monthly equivalents are not verified deposits or exact pay dates |
| Spending | My Money → Spending → Budget editors | Category lists and allocations; create, rename, reclassify, archive, restore, and reallocate | Monthly plans, confirmed actuals, pending reviews, and approved baseline observations remain distinct |
| Debt | My Money → Debt | Household tracking mode and saved records; add, edit, archive, restore | Optional challenge card terms require their own dated review |
| Accounts | My Money → Accounts | Saved balances and dates; add, edit, archive, restore, review existing bank observations | Account balances do not automatically count toward challenge savings |
| Goals | My Money → Goals | Household tracked targets and progress; add, edit, archive, restore | A tracked goal does not change the accepted challenge target or move money |
| Statements | Statements, also linked from My Money | Attach an upload and request help; review source/account/row decisions in their dedicated controls | Document observations never silently replace approved household records |

Profile retains starting-picture setup, preferences, memory, and bank authorization.
Existing Profile and Budget links remain available. Bank consent, uploads, private
exports, and final financial approvals use their dedicated controls.

## Required scenarios

Run ordinary and BOG participant workflows with fictional records. Check desktop,
tablet, 390px mobile, 320px mobile, and mobile WebKit. Native iPhone/Android testing
is separate from browser viewport testing.

1. Find every topic from Home. Switch topics, use browser Back/Forward, and follow
   an existing Profile or Budget link. Check disabled capabilities and bank OAuth
   returns. Topic controls and menus must fit and retain visible keyboard focus.
2. Enter multiple income sources, including identical names with different types,
   a future source, an ended source, a scheduled raise, a scheduled zero, and a
   one-time bonus. Compare selected-month and annual totals to the existing timeline
   calculation. Read the same facts through Mia; disclose bounded lists and unknown
   or incomplete coverage. A read must not create an annual plan.
3. Create and update a category manually and through Mia in each program. Check
   every before/after value, selected month/year, and allocation. Cancel leaves
   approved data unchanged; applying updates the same records as the manual editor.
   Confirmed actual spending and challenge savings must not change.
4. Exercise income, debt, account, and tracked-goal edit families. Check unknown
   versus explicitly entered zero, duplicate names, archive/restore history,
   invalid dates/amounts, scheduled effective months, and stale edits.
5. Ask an ambiguous BOG goal or card question. Clarify household versus challenge
   scope. Household actions must not become challenge contributions, purchases,
   target changes, baseline approvals, or optional card-term approvals.
6. Report a BOG purchase and money set aside. Exact entries should prepare review
   input, not count automatically. Preserve ambiguity, future-date, unreserved-money,
   and duplicate-request protections.
7. Repeat a message and approval with the same request identity. Change content
   while reusing an identity, interrupt/retry, switch programs, clear chat with a
   pending card, revoke membership, and place the challenge on hold. Verify that
   review origin survives chat deletion and inaccessible cards cannot apply/cancel.
8. Review the same saved household card through optional challenge terms. Check
   explicit dated import/link, stale household facts, conflicting versions,
   duplicate links, participant/cohort ownership, correction, unlink, rollback,
   and immutable approved history. Neither surface silently updates the other.
9. Check long labels, large values, empty lists, loading, failed requests, and
   unsaved edits. Inspect the top and bottom of dialogs, landscape height, keyboard
   focus and dismissal, and page/section overflow.
10. Use the configured live provider with synthetic records to verify natural
    language reads, single edits, multiple edits, clarification, and challenge
    coaching. Deterministic and mocked-provider tests alone do not establish live
    model reliability.

## Release gate

Run Rails tests, autoload checks, RuboCop, Brakeman, and dependency audit. Run web
lint, design/privacy checks, unit tests, production build, dependency audit, and
the configured Chromium/WebKit suite. Record CUA observations and screenshots.
Review the exact final commit, resolve material findings, merge only a ready PR,
and verify the frontend deployment and API/schema deployment independently.

Production smoke checks must avoid fictional writes to participant records.
Local QA databases, servers, browser tabs, and test processes are task-owned and
must be cleaned. Physical-device and real-participant pilot acceptance remain
explicit evidence requirements, even when automated browser checks pass.
