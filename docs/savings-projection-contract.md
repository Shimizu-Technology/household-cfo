# Savings projection contract

`HouseholdFinance::SavingsProjection` calculates one enrollment's participant-reported new money set aside and the evidence-supported subset. It is a pure calculation component for S06. It does not create, approve, authorize or share records, and it does not make the complete pilot available.

Call it with `entries:`, `cutoff_on:`, optional `target_cents:`, `reporting_known:` and `zero_attested:`. The result is an immutable hash containing integer cents and a JSON-compatible progress bar measured in basis points: 10,000 means 100%. The bar is clamped to 0–10,000 and rounded down; achievement compares exact cents independently. Reported cents remain signed and can exceed the target. A missing target is `nil`, with no percentage or achievement value. Zero and negative targets are invalid.

Each entry is a plain Hash with exactly these symbol keys:

| Key | Required value |
| --- | --- |
| `logical_entry_id` | Stable string identifying the financial entry across revisions |
| `version_id` | Unique immutable version identity string |
| `approval_state` | `approved` or `draft` |
| `current_head` | Boolean; every approved input must be the caller-selected current approved head |
| `effective_on` | `Date` or strict `YYYY-MM-DD` calendar date |
| `signed_cents` | Integer; positive contribution, negative reserve withdrawal; zero permits a corrected entry with no remaining amount |
| `currency` | `USD` |
| `funding_source` | One of the classifications below |
| `evidence_supported_cents` | Reviewed supported portion of a contribution, from zero through its amount; always zero for withdrawals |

Identity strings use ASCII letters, digits, underscores, periods, colons or hyphens, start with a letter or digit, and contain at most 128 characters. Convert database identities deliberately in the caller adapter. Amounts are never parsed from currency strings, rounded from floats or coerced from missing values.

Eligible classifications are `earned_income`, `gift`, `bonus` and `new_money_reserved`. Each denotes an approved reservation of NEW money for the challenge, not receipt of money alone. `new_money_reserved` can describe a reviewed transfer funded by new money; it cannot be used to relabel existing savings. `preexisting`, `borrowed`, `cash_advance` and `existing_internal_money` are retained as excluded entries and do not create progress, even with evidence. New income, gifts or bonuses do not establish that spending cuts caused the savings.

Only `withdrawal` denotes money removed from this challenge reserve. It must be nonpositive and cannot add evidence. A negative movement from an existing savings account is not a challenge withdrawal. Bank events, opening balances, spending reductions, refunds, unused budget and debt payments cannot enter the projector directly or create automatic contributions. The caller must prepare and obtain approval for a distinct eligible reservation.

Only approved heads effective on or before the inclusive cutoff count. Drafts do not count. A pending draft correction may share its logical identity with the still-current approved head, but it has a different version identity. Select the current **approved financial head** independently of pending draft heads. Passing two approved versions for one logical entry, an approved version marked noncurrent or duplicate version identities fails closed. Every input is validated, including drafts and future-dated entries; a cutoff cannot conceal malformed data.

`reporting_known: false` returns `nil` for reported money, supported money, contribution/withdrawal totals, achievement and progress, even if input entries are present. It never substitutes zero. An empty eligible ledger with `reporting_known: true` requires `zero_attested: true`: an approved, cutoff-specific statement that reported net progress is zero. Excluded entries or future entries alone cannot establish known zero. Approved entries whose net is zero, including corrected zero heads, can establish a calculated zero. A zero attestation contradicting a nonzero net is rejected. This flag reports knowledge of the participant's approved reported result; it is not evidence that every account or transaction has been captured.

Contributions create FIFO lots ordered by effective date, then logical identity using byte-compatible ASCII ordering. Withdrawals consume earlier lots. Within a partially supported lot, supported cents are consumed first. A withdrawal exceeding available lots carries forward and consumes the next contribution's supported cents first. This conservative allocation is a reporting rule; it does not identify which physical dollars moved.

For example, supported $200, unsupported $100 and a $150 withdrawal leave $150 reported and $50 supported. A $100 contribution with $50 of reviewed evidence and a $25 withdrawal leaves $75 reported and $25 supported. A $150 withdrawal followed by supported $200 and unsupported $100 also leaves $150 reported and $50 supported. Supported savings never exceeds positive reported net savings; negative reported net has zero support. Do not add supported and reported totals together.

Corrections replace a logical entry's current approved head, preserving its effective date and identity unless an approved correction changes the date. They do not append another contribution to the projected input. A zero head can remove an erroneous contribution while the immutable history remains outside this service. An actual later withdrawal is a separate entry with its own identity. Evidence promotion or removal changes the supported amount and immutable version identity, without changing reported cents. Evidence is an already-reviewed aggregate allocation; do not sum two bank legs of one reservation to double its supported amount.

The caller must select authorized enrollment records, current approved versions **as of the requested approval sequence/time**, the effective-date cutoff, accepted target version and any valid zero attestation server-side. Replaying a historical cutoff against today's corrected heads is a revised projection, not the original checkpoint. Preserve the selected version identities, calculation version, accepted target and reporting/attestation state with a checkpoint. `included_version_ids` lists only the counted eligible heads in calculation order; record excluded heads separately when preserving a full selection snapshot. Closed checkpoints need explicit revisions when their inputs change.

Persistence, immutable version history, optimistic locking, actor and participant consent, funding eligibility review, approval, idempotency, source evidence validity, household allocation limits and prevention of allocation reuse across enrollments/programs remain caller responsibilities. A boolean `current_head` is a contract assertion, not an authorization check or proof of persisted state. Do not pass user-supplied head flags or evidence totals directly. This service neither discovers duplicate economic reservations with different logical identities nor grants access to its output; participant, coach and sponsor serializers must enforce their separate sharing rules.

The domain tests cover the relevant arithmetic and strict input portions of SAVE-01–04, SAVE-07–08, SAVE-10–19 and SAVE-26–27. They also exhaustively compare all 2,800 sequences of one to four small contribution/withdrawal events against a separate per-cent FIFO oracle. Database approval races, retries, shared allocations, program overlap, UI and export acceptance remain integration work.
