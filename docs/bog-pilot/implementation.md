# BOG pilot implementation

Dated local snapshot: October 5, 2026, 08:10 Pacific/Guam (October 4, 22:10 UTC). The final release PR must identify its exact head and CI. The integration owner’s final evidence addendum supersedes pending engineering results below; human launch holds require explicit acceptance.

The pilot serves 30 participants for 90 days, with a default $500 savings target. Participants can accept a smaller affordable target or postpone choosing one. Debt, credit cards, bank linking and a complete annual budget are optional. Mel provides coaching and Leon provides technical support.

## Measurement contract

Count only participant-approved new money set aside, less withdrawals. Lower spending, unused budget, refunds, debt payments and bank balance increases do not create savings entries automatically. Exclude preexisting reserves and borrowed funds. Evidence-supported progress is a subset of reported savings, never an additional total. Store exact integer cents, approval, effective date and immutable correction history.

Allocate withdrawals against contribution lots by effective date and stable identity, oldest first. Within a partially supported lot consume supported cents first. Evidence support cannot exceed positive reported progress. A supported $200 contribution followed by unsupported $100, then a $150 withdrawal, leaves reported $150 and supported $50. Unknown progress is distinct from zero; negative progress remains visible.

Keep reported savings, evidence support, comparable spending change and optional debt results separate. Financial document extraction, reconciliation and participant approval are separate boundaries. Every source row must be accounted for, including deposits, transfers, refunds, fees, card payments and nonposted informational rows. Preserve existing approved spending records and their meaning.

## Delivery sequence

| Slice | Scope | Status |
|---|---|---|
| S01 | Existing debt/setup correctness, compact chat, current Home year, partial review visibility, durable source cleanup | Merged in PR146; integrated acceptance still required |
| S02 | Frozen release contracts and a versioned savings experience | Merged in PR147; historical contracts remain immutable |
| S03 | Typed source events, reconciliation, evidence links, authenticated revocable source viewing | Merged PR148 at 451c250; separate deployment evidence recorded, new integration acceptance still required |
| S04 | Paginated statement review, account/period coverage, corrections and overlap resolution | Implemented; API PR149 merged at 88b2c0c with passing local/backend CI gates; frontend/deployed/human acceptance pending |
| S05 | Approved baseline versions and full-window patterns | Implemented; API PR149 merged at 88b2c0c with passing local/backend CI gates; frontend/deployed/human acceptance pending |
| S06 | Enrollment, accepted plan versions and reviewed savings ledger | Implemented; API PR149 merged at 88b2c0c with passing local/backend CI gates; frontend/deployed/human acceptance pending |
| S07 | Daily entries/reflections, no-spend and missed-day states, day30/60/90 checkpoints | Implemented; API PR149 merged at 88b2c0c with passing local/backend CI gates; frontend/deployed/human acceptance pending |
| S08 | Scoped coach sharing, support and privacy-preserving exports | Implemented; API PR149 merged at 88b2c0c with passing local/backend CI gates; frontend/deployed/human acceptance pending |
| S09 | Durable consented prompts, recovery and measured concurrency | Implemented; API PR149 merged at 88b2c0c with passing local/backend CI gates; frontend/deployed/human acceptance pending |
| S10 | Sealed coaching release, full rehearsal and launch gate | Acceptance and human launch hold; no invitation or outbound activation |

The source cleanup outbox persists in the primary database before deleting an import. Storage or queue failure leaves durable retry work. Recovery runs every five minutes under the configured production Solid Queue scheduler. Cleanup preserves approved financial records. The integrated S03 source viewer checks authorization on every new application read and returns private bytes rather than a reusable storage bearer URL. Real deletion-failure/provider and deployed revocation acceptance remain open. Already downloaded copies cannot be recalled.

## Experience and privacy

Home should show the personal challenge day, accepted target, reported progress, evidence status and next action. Mia gets the available screen height; help collapses, the composer stays reachable and attachment trays are bounded. Statements/review remain directly available without full setup. Desktop, tablet, 390-pixel and 320-pixel phone layouts require actual browser verification.

Each enrollment uses a frozen Pacific/Guam calendar. An early enrollee starts on the configured cohort start; an accepted late enrollee receives a personal 90-day window. November 1, 2026 is a test fixture, not a booked launch: inclusive checkpoints are November 30, December 30 and January 29. Device timezone changes cannot shift challenge dates silently.

Raw documents, chat, reflections and finances are private by default. Basic coach participation/support access does not grant amounts or detailed records. Monetary and detailed sharing require separate scoped grants with revocation. Sponsor reports use fixed scheduled coarse cohort summaries with small-cell and complement/differencing suppression. No sponsor individual drilldown or dynamic department filtering.

Prompts are in-app by default, with optional consented generic email. Notifications contain no amounts, merchants or feelings. No WhatsApp automation. Missing a prompt or check-in means unknown, not zero spending. Late evidence must be reviewed without erasing a participant’s reflections.

## Acceptance and rollout

The companion `test-matrix.csv` contains 209 independent acceptance cases. The October 5 evidence audit records 3 PASS, 179 NOT RUN and 27 BLOCKED full acceptance scenarios, with specific related assertions and partial runtime evidence. None is promoted to PASS from a generic engineering suite. `testing-plan.txt` describes the realistic journeys and appropriate layers. Green engineering checks alone do not establish pilot readiness.

Each slice requires the complete repository gate, affected live browser flows, current-head reviewer coverage, resolution of material findings, merge and exact-commit deployment verification. Final rehearsal covers debt-free and indebted participants, independent real checking/wallet statement oracles, fictional card oracles, 30 mixed synthetic participants, interrupted providers/workers and access revocation. Synthetic cards do not prove compatibility with every issuer.

Before invitations, settle the actual start date, support availability, final consent/retention wording and sponsor report template; obtain Mel’s acceptance of the concrete coaching flow. Real iPhone Safari and Android Chrome need usability verification in addition to emulation. Keep the pilot behind a release hold until the launch criteria pass. Do not roll back by dropping approved participant data.

The original evidence audit inspected integration `36100012c01fd2fa9a1011f5cf11f24729177d86`; this documentation base is `9c947c752932fce4fb1df02fcf514b0539f503e7`. API tree `092a6799a9243a29b3ca8ba4012c0f82543fada7` matches tested e3b0ffd and merged API PR149 at 88b2c0c: 2,567 tests/39,620 assertions pass with two workers, plus 1,040-file lint, autoload, security and advisory checks. Exact Render deployment and HTTP health are verified. Current repaired release `04c36757a1316e3e8fcc4e88c825ac04cc59e481` has web tree `9453a6634def63f357c8a74643e237412c007351`, unchanged API bytes, 612 passing units and completed lint/typecheck/build; audit finds zero vulnerabilities. Historical E24 remains FAIL (1,043 passing/82 skipped/13 failed). Bounded Coach, Debt fixture and evidence recovery repairs pass in E27/E29/E31/E32; the new 1,150-case full browser gate is PENDING in E33. Actual local HTTP/outbox/restore rehearsals pass within their stated synthetic scopes. Normal deployed authentication, complete provider/device journeys and human acceptance remain launch holds. [Readiness evidence](readiness-evidence.md) pins artifacts, commits and limits; [operations runbook](operations-runbook.md) covers recovery and preserving private financial history.

Use [Mel’s acceptance packet](mel-acceptance-packet.md) for the proposed calendar, coaching examples, voluntary participation, support, privacy and retention decisions. It is a review document; no decision, invitation or start date is accepted by its creation.

A native program switch found that Ask Mia restored chat from the original program even though Home cleared its savings panels. E15 preserves that failure. E16 verifies the central session/status/idempotency repair, migration, exact API gate and native program rerun. It preserves eight original message content digests and prevents original financial facts appearing in the new program. Account logout/login, normal deployed authentication and the broader launch holds remain unexecuted.
