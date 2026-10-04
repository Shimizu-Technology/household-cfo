# BOG pilot implementation

The pilot serves 30 participants for 90 days, with a default $500 savings target. Participants can accept a smaller affordable target or postpone choosing one. Debt, credit cards, bank linking and a complete annual budget are optional. Mel provides coaching and Leon provides technical support.

## Measurement contract

Count only participant-approved new money set aside, less withdrawals. Lower spending, unused budget, refunds, debt payments and bank balance increases do not create savings entries automatically. Exclude preexisting reserves and borrowed funds. Evidence-supported progress is a subset of reported savings, never an additional total. Store exact integer cents, approval, effective date and immutable correction history.

Allocate withdrawals against contribution lots by effective date and stable identity, oldest first. Within a partially supported lot consume supported cents first. Evidence support cannot exceed positive reported progress. A supported $200 contribution followed by unsupported $100, then a $150 withdrawal, leaves reported $150 and supported $50. Unknown progress is distinct from zero; negative progress remains visible.

Keep reported savings, evidence support, comparable spending change and optional debt results separate. Financial document extraction, reconciliation and participant approval are separate boundaries. Every source row must be accounted for, including deposits, transfers, refunds, fees, card payments and nonposted informational rows. Preserve existing approved spending records and their meaning.

## Delivery sequence

| Slice | Scope | Status |
|---|---|---|
| S01 | Existing debt/setup correctness, compact chat, current Home year, partial review visibility, durable source cleanup | Implementation and verification underway |
| S02 | Frozen release contracts and a versioned savings experience | In progress on an isolated branch |
| S03 | Typed source events, reconciliation, evidence links, authenticated revocable source viewing | Pending |
| S04 | Paginated statement review, account/period coverage, corrections and overlap resolution | Pending |
| S05 | Approved baseline versions and full-window patterns | Pending |
| S06 | Enrollment, accepted plan versions and reviewed savings ledger | Pending |
| S07 | Daily entries/reflections, no-spend and missed-day states, day30/60/90 checkpoints | Pending |
| S08 | Scoped coach sharing, support and privacy-preserving exports | Pending |
| S09 | Durable consented prompts, recovery and measured concurrency | Pending |
| S10 | Sealed coaching release, full rehearsal and launch gate | Pending |

The source cleanup outbox persists in the primary database before deleting an import. Storage or queue failure leaves durable retry work. Recovery runs every five minutes under the configured production Solid Queue scheduler. Cleanup preserves approved financial records. S01 still uses the existing source-view URL mechanism; authenticated application reads and immediate denial of new source reads belong to S03. Already downloaded copies cannot be recalled.

## Experience and privacy

Home should show the personal challenge day, accepted target, reported progress, evidence status and next action. Mia gets the available screen height; help collapses, the composer stays reachable and attachment trays are bounded. Statements/review remain directly available without full setup. Desktop, tablet, 390-pixel and 320-pixel phone layouts require actual browser verification.

Each enrollment uses a frozen Pacific/Guam calendar. An early enrollee starts on the configured cohort start; an accepted late enrollee receives a personal 90-day window. November 1, 2026 is a test fixture, not a booked launch: inclusive checkpoints are November30, December30 and January29. Device timezone changes cannot shift challenge dates silently.

Raw documents, chat, reflections and finances are private by default. Basic coach participation/support access does not grant amounts or detailed records. Monetary and detailed sharing require separate scoped grants with revocation. Sponsor reports use fixed scheduled coarse cohort summaries with small-cell and complement/differencing suppression. No sponsor individual drilldown or dynamic department filtering.

Prompts are in-app by default, with optional consented generic email. Notifications contain no amounts, merchants or feelings. No WhatsApp automation. Missing a prompt or check-in means unknown, not zero spending. Late evidence must be reviewed without erasing a participant’s reflections.

## Acceptance and rollout

The companion `test-matrix.csv` contains 209 independent acceptance cases; its status records execution, not intention. `testing-plan.txt` describes the realistic journeys and appropriate layers. Green engineering checks alone do not establish pilot readiness.

Each slice requires the complete repository gate, affected live browser flows, current-head reviewer coverage, resolution of material findings, merge and exact-commit deployment verification. Final rehearsal covers debt-free and indebted participants, independent real checking/wallet statement oracles, fictional card oracles, 30 mixed synthetic participants, interrupted providers/workers and access revocation. Synthetic cards do not prove compatibility with every issuer.

Before invitations, settle the actual start date, support availability, final consent/retention wording and sponsor report template; obtain Mel’s acceptance of the concrete coaching flow. Real iPhone Safari and Android Chrome need usability verification in addition to emulation. Keep the pilot behind a release hold until the launch criteria pass. Do not roll back by dropping approved participant data.
