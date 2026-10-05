# Challenge privacy, support and fixed sponsor reports

S08 adds a private backend domain for separate sharing choices, selected support records and disclosed source retention. It does not create sponsor accounts, send messages or grant technical administrators permission to browse a participant's finances. Root integration owns routes, controllers, Registry/Runner/catalog registration, minimized serializers, source proxies, consent UI and the production checkpoint adapter.

## Actor and consent contract

All six operations are version 1, `ACTOR_REQUIRED = true`, `SENSITIVE_AUDIT = true`, and construct with `new(household, user:)`:

| Key | Action | Result |
| --- | --- | --- |
| `privacy.consent.set` | Grant or revoke one separate sharing purpose | Immutable `ChallengePrivacyEvent` |
| `support.request.create` | Participant-approved concise request and selected references | Immutable event referring to a ticket |
| `support.access.grant` | Exact recipient, selected records, reason and expiry | Immutable event referring to support access |
| `support.access.revoke` | Revoke exact support access | Immutable event |
| `source_use.authorize` | Disclose and authorize one exact enrollment's source use | Immutable event referring to a use |
| `source_use.revoke` | Owner-authorized global original deletion, affecting every use | Immutable event referring to the original import |

Every request identifies `enrollment_id`; server actor and household identity are never accepted from input. Prepare, execution and replay recheck the actual participant and current owner/partner household membership under the household lock. Sharing grants, support requests and source-use authorization also require the current S06 challenge access policy. Privacy revocation and original deletion retain the participant's rights after withdrawal, cohort hold or removed program membership. A household partner cannot mutate another participant's enrollment consent.

`privacy.consent.set` requires exactly `enrollment_id`, `kind`, `recipient_user_id`, `granted`, `selected_records`, `expires_at`, `policy_version`, `expected_grant_id`, and `expected_lock_version`. The fixed policy version is `challenge_privacy_v1`. Purposes are `coach_summary`, `selected_details`, and `sponsor_aggregate`; participation alone grants none. Sponsor inclusion uses a null recipient and no detailed records. Coach sharing chooses an exact current program staff recipient with an explicit workspace membership. Selected details require an expiry and between one and twenty exact records. Expiring grants may be no longer than 366 days. No wildcard, household-wide or future-record scope exists.

Records use `{record_type, record_id}`. Supported types are `document_source`, `source_review_version`, `savings_entry_version`, `savings_plan_version`, and `chat_message`. Sources and approved source facts follow existing household ownership; plan/savings records and chat messages also require the actual personal enrollment/user. IDs are checked on preparation and each shared read. Reflections are deliberately unavailable until the root connects the separate S07 personal-reflection ownership policy; chat permission cannot substitute for reflection permission.

The grant head has an optimistic lock. Immutable events record the participant's exact reviewed private choice. Generic financial operation audit/execution mirrors must stay empty through the root's sensitive Runner. The private event table may retain approved support text, reasons and exact selected references; those values must not be copied to analytics, general logs, sponsor responses or broad workspace serializers.

## Coach and support reads

`ChallengePrivacy::SharedReader.new(enrollment, user:)` provides `basic`, `summary`, `selected(record_type:, record_id:, support_access_id: nil)`, `support_ticket(ticket_id)`, and `update_support_status(ticket_id, status:)`.

Basic reads expose enrollment ID, participation/setup status and the recipient's help-request references/status. Money requires an active `coach_summary` grant for that recipient. Summary contains only the accepted target and the existing approved reported/evidence-supported projection fields. Selected reads return the exact authorized model for a root-owned minimized serializer or authenticated source proxy; they never return `.attributes`, raw storage URLs or a full workspace. Raw statement reads also require a currently available source lease.

Each shared read rechecks actual participant membership plus current staff role, explicit workspace membership and the recipient's actual program assignment. Platform-admin role alone is insufficient. Role removal, grant revocation, source revocation and expiry block the next read. Successful private reads append an immutable journal of actor, purpose and exact record identity without financial values, merchant names, chat content or feelings. Downloaded copies cannot be recalled.

Support requests require `enrollment_id`, exact `recipient_user_id`, `issue_kind` (`technical`, `coaching`, `access`, `other`), a participant-reviewed message of at most 500 characters and `selected_records` (empty by default). Ticket sharing exposes only those deliberate fields; it does not attach logs, household financial values or raw sources automatically. Ticket ownership is the chosen recipient, and status can progress to `triaged` or `resolved` through the guarded reader.

Additional support access requires `ticket_id`, matching recipient, exact selected records, reason, `expires_at` and `expected_ticket_lock_version`, plus the enrollment. Access expires within 24 hours and cannot be broadened or revived by editing the approved scope. Revoke names `access_id` and `expected_lock_version`. A new participant approval is required for another scope or duration. The ticket's deliberate message remains readable to its current assigned recipient; expiry applies to additional private-record access.

S07 check-in status is an integration seam: the current basic domain has no check-in or reminder-delivery inference. Root must add only current attendance/status through the S07 reader, preserving private reflections and the distinction between an undelivered reminder and participant inactivity.

## Source uses and cleanup

`ChallengePrivacy::SourceRetention` exposes owner-only `describe(source)`, read predicate `.available?(source)`, authorized-use mutation through the operation, global revoke through the operation, and system `expire!(source)`.

Source authorization requires `document_import_id`, disclosure version `personal_end_plus_30_days_v1`, exact `expected_expires_at`, `expected_use_id` and `expected_lock_version`, plus enrollment. Expiry is the participant's inclusive personal end-of-day in their pinned timezone plus thirty days. A new program join never creates or extends a source use. Multiple explicit uses retain the original through the latest unrevoked expiry. Existing originals with no new explicit uses retain their existing source policy; this domain does not silently assign them a challenge expiry.

The owner sees each affected use and latest explicit expiry before deletion. Global revoke requires the digest of that exact `affected_uses` list. Any use change conflicts with an older review. Current owner/partner permission follows existing writable household source permissions; a coach cannot extend or veto source retention. The domain immediately revokes every use, marks the original unavailable, erases disposable extraction evidence and creates/reuses the durable `FinancialDocumentSourceCleanup` primary outbox. It makes no S3 call or outbound queue request. Approved events, source versions, account identities and financial records remain. Import references may later be FK-nullified without removing use history.

Expiry takes household then source locks and checks the latest explicit uses again. An active later use prevents early cleanup. Expired leases deny raw access before physical cleanup succeeds. Root must call the predicate on every authenticated source GET and recheck it after rendering/download, integrate source-use descriptions into delete/authorization UI, and run the expiry sweep and existing cleanup/recovery workers. Current direct household source endpoints do not gain coach access merely because a grant exists; root must use the guarded selected-record path.

Provider and backup retention remain separate operational policies. `describe` explicitly reports that provider/backup retention has not been verified and previously downloaded copies are not retrievable. No unsupported provider deletion deadline is promised.

## Fixed sponsor exports

`ChallengePrivacy::SponsorExports.new(cohort, user:, adapter:)` provides `approve(checkpoint_day:, resolved_cutoff_on:, policy_version:)`, `read(export_id)` and `csv(export_id)`. The policy is `fixed_coarse_min5_v1`; only Day 30/60/90 is supported, in increasing seal order. Cohort capacity is at most thirty. Operators need current staff role, explicit workspace owner/reviewer permission and an actual assignment to the cohort. The domain creates no sponsor login or individual drilldown.

The default `CheckpointAdapter` fails closed. A trusted production subclass must resolve immutable, approved S07 checkpoint inputs and validate their pinned ledger/target/plan/cutoff/version. Its exact output is `{enrollment_id, checkpoint_id, checkpoint_version, cutoff_on, digest, band}`. Digests are SHA256, cutoff is exact ISO date, checkpoint IDs are distinct for each participant, and no raw financial amount may enter this export contract. Bands are `at_target`, `below_target`, `unknown`, `final_pending`, `custom_target`, `no_target`, `late_window`, and `withdrawn`. The adapter must choose them using the approved target/window and final-confirmation state; it cannot substitute today's bank balance, provisional drafts or an invented failure/zero.

The report contains coarse count ranges, qualifications and suppression state. No names, roster, departments, household details, merchants, feelings, exact personal savings or exact cohort money total appear. Bands count participant outcomes; there is no sum that could duplicate a shared household event. Shared savings allocations must still be validated in the savings/checkpoint domain before classification.

Any nonzero cell or complement smaller than five suppresses the whole financial breakdown. A small unconsented complement also suppresses it and the denominator. No dynamic subgroup, custom date, policy variation or alternate cutoff can rebuild the same checkpoint. Changes affecting one to four participant bands or inclusion states between checkpoints suppress the new breakdown. These controls reduce disclosure; they do not guarantee anonymity or establish program causality.

The immutable export identity is cohort/checkpoint/policy, with the reviewed cutoff pinned. A repeated request reads that same sealed report without consulting fresh checkpoint observations. Every repeat checks current consent, membership, participation status and recipient permissions. A changed grant/expiry/roster/status invalidates the report and cannot trigger a replacement for the same checkpoint. Previously downloaded reports remain outside recall. CSV output quotes formula-leading values, including preceding whitespace, and contains only report fields.

## Validation and integration limits

The worktree initially used `5db5d2b`; the parent authorized merging `61c9e88` when the earlier V3 registry could not seal its current fixture. The combined schema was regenerated by migration from zero in the explicitly named disposable `bog_privacy_support_test` database, then loaded fresh. Root-owned release/Registry/controller changes arrived only through that merge. No controller, route, Runner, catalog or frontend was authored in S08.

The focused service/operation tests exercise separate consent, exact IDs, current role/membership, optimistic conflicts, expiry, withdrawal-time revocation, retained approved facts, raw evidence erasure, cells/complements, fixed replay, differencing and formula escaping. They do not certify HTTP response minimization, source streaming races, accepted disclosure UI, real checkpoint classification or sponsor/support browser journeys. Root must run those integrated request and UI checks before launch.

The final backend suite passed with 2,330 tests and 37,570 assertions; the focused privacy suite passed with 23 tests and 131 assertions. RuboCop checked 900 files without offenses; Brakeman reported zero errors and zero warnings; bundler-audit found no vulnerabilities; Zeitwerk passed. Migration from zero and fresh combined-schema loading passed. The independent PostgreSQL check produced one consent approval and one stale conflict, one fixed export with five checkpoint-adapter reads, a denied export after consent revocation, and zero replacement reports. The inherited source-accounting regression was updated using the parent's committed `8e42342` test, preserving real source approval, projection and re-extraction lineage checks.

Request-log filtering is also a root integration dependency. Existing filters cover financial reasons and chat content, but the new support `message` and grant `selected_records`, `recipient_user_id`, `granted`, and `expires_at` fields need explicit filtering before endpoints are exposed. Sensitive Runner markers alone do not redact Rails request parameters or frontend analytics.

Use the exact disposable test URL for every Rails command:

```sh
DATABASE_URL=postgresql:///bog_privacy_support_test \
DATABASE_TEST_NAME=bog_privacy_support_test RAILS_ENV=test PARALLEL_WORKERS=1 \
bin/rails test test/services/challenge_privacy_test.rb
```

`test/scripts/challenge_privacy_concurrency.rb` requires `PRIVACY_CONCURRENCY_DISPOSABLE_DATABASE=bog_privacy_support_test`, tests independent PostgreSQL connections, and commits synthetic immutable records. Run it after the ordinary suite, then drop only that owned database. No real participant, private PDF, provider model, raw S3 object, server or browser tab is needed for this domain gate.
