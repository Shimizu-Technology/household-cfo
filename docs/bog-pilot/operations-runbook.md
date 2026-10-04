# BOG pilot operations runbook

Keep the pilot on release hold until the acceptance and human decisions in [readiness evidence](readiness-evidence.md) are complete. This runbook documents existing recovery seams at integration `dfffba7`; no command here was executed by the documentation audit. It authorizes no invitations, sharing grants, email, WhatsApp messages, deployment or release activation.

Mel owns coaching and participant-facing flow acceptance. Leon owns technical operations, incident coordination and evidence recording. A BOG escalation contact, support hours and response promise remain launch decisions. Technical access does not grant permission to browse private financial records; use participant-chosen, time-bound support access and retain only sanitized issue metadata.

## Before any execution

Verify the host, exact commit, current sealed cohort release, selected cohort ID, environment and database name. Use an explicit `RAILS_ENV` and `DATABASE_URL` for every Rails maintenance/test command. Every local test command must also set `DATABASE_TEST_NAME` to exactly the database named by the URL. Validate the sanitized database/host identity before migrating or testing. The disposable-database guard must remain strict; a missing or mismatched test name is an invocation error, not a reason to weaken it. Obtain credentials through the existing authorized secret channel; do not print URLs, environment files, tokens, private source keys or SMTP settings. Record operator, reason, scope, time, preconditions, exact command and sanitized result in a private incident record.

For local rehearsal use a named disposable database, fixed clock and synthetic identities. Never allow an unset URL to fall back to development. `api/bin/ci` replants seeds and must not run against a preserved development or production database. Apply local-dev-lifecycle: record baseline, claim each exact server/tab/DB/storage delta and clean only that delta. Preserve shared services.

Set `BOG_DISPOSABLE_DATABASE_NAME` and `BOG_DISPOSABLE_DATABASE_URL` to a verified, task-owned test database before using these examples; neither may be empty, and both must identify the same database. Use the repository-supported Ruby (3.3.7 for E06) and run the existing gates from `api/` or `web/` as appropriate:

```sh
RAILS_ENV=test DATABASE_URL="$BOG_DISPOSABLE_DATABASE_URL" DATABASE_TEST_NAME="$BOG_DISPOSABLE_DATABASE_NAME" PARALLEL_WORKERS=1 bin/rails db:prepare
RAILS_ENV=test DATABASE_URL="$BOG_DISPOSABLE_DATABASE_URL" DATABASE_TEST_NAME="$BOG_DISPOSABLE_DATABASE_NAME" PARALLEL_WORKERS=1 bin/rails test
RAILS_ENV=test DATABASE_URL="$BOG_DISPOSABLE_DATABASE_URL" DATABASE_TEST_NAME="$BOG_DISPOSABLE_DATABASE_NAME" bin/rails zeitwerk:check
RAILS_ENV=test DATABASE_URL="$BOG_DISPOSABLE_DATABASE_URL" DATABASE_TEST_NAME="$BOG_DISPOSABLE_DATABASE_NAME" bin/rubocop
RAILS_ENV=test DATABASE_URL="$BOG_DISPOSABLE_DATABASE_URL" DATABASE_TEST_NAME="$BOG_DISPOSABLE_DATABASE_NAME" bin/brakeman --no-pager
RAILS_ENV=test DATABASE_URL="$BOG_DISPOSABLE_DATABASE_URL" DATABASE_TEST_NAME="$BOG_DISPOSABLE_DATABASE_NAME" bin/bundler-audit check --update
```

```sh
npm ci
npm run lint
npm test
npm run build
npm run test:browser
npm audit --audit-level=moderate
```

Inspect the target head's CI/reviewer requirements again; these commands do not substitute for required checks. Use the supported repository Ruby/Node versions and an explicitly owned browser server. A mock browser pass is not deployed auth/provider proof.

## Hold and rollback

The current participant guard checks `savings_challenge_enabled`, `savings_challenge_release_hold`, current role/membership and the sealed savings release on every new financial operation/read (`api/app/services/savings_challenge/access_policy.rb:22`). Existing prepared-operation replay also reauthorizes. Hold denies new financial activity; self-only privacy revocation, reminder disable/dismissal and reflection erasure are deliberately available without granting financial reads.

At this snapshot the ordinary admin cohort update does not permit the savings hold field (`api/app/controllers/api/v1/admin/cohorts_controller.rb:94`). Do not invent an unaudited public endpoint. If an authorized incident requires a hold, Leon can use a reviewed maintenance transaction against the verified cohort only; record its operator/reason externally as sanitized operational metadata. Example, after explicit environment/database and cohort verification:

```sh
RAILS_ENV=production DATABASE_URL="$BOG_VERIFIED_DATABASE_URL" bin/rails runner 'cohort = Cohort.find(Integer(ENV.fetch("BOG_COHORT_ID"))); cohort.with_lock { cohort.update!(savings_challenge_release_hold: true) }; puts "Challenge hold applied"'
```

This example is a maintenance option, not launch approval. Do not set the hold false until the exact sealed release, acceptance record, migration/runtime compatibility, current gates and smoke are approved. Stop only the specific task/incident-owned workers when needed; a hold is not permission to stop shared services.

Prefer forward fixes or an explicitly compatible previously sealed runtime. Never modify sealed bytes, remove operation-version validation, bypass compatibility caches, drop savings/source tables, delete approved versions or mutate approved progress to accomplish rollback. Keep pending work and approved financial history. Recheck the selected release and old/current contracts after rollback, and document changes to access separately from money. The frozen contract regressions are `api/test/services/cohort_release_contract_versions_test.rb:11` and `:109`; they are not a production rollback rehearsal.

## Uncertain participant actions

Use the existing original `Idempotency-Key` and the same actor/household/cohort/enrollment/action to query the feature's `request_status` endpoint. The savings, daily, source review, baseline, privacy, evidence and optional-debt adapters have separate status routes (`api/config/routes.rb:10`). Do not invent a new key or approve a second contribution because a response was lost.

A committed response must match the current private scope exactly. In-flight is pending metadata; optional debt can return a nil enrollment at a bounded household-lock timeout, which grants no financial result. Unknown allows only the adapter's reviewed retry path with the original key. A changed payload can conflict; inspect current authorized facts and stage an explicit correction. Never force an operation execution to succeeded or overwrite a prior approved head in SQL. Recovery identity may persist; financial payloads must not be placed in browser storage or generic audit mirrors.

## Primary outboxes and workers

Production recurring tasks in `api/config/recurring.yml:12` schedule reminder recovery, source lease expiry and source cleanup recovery every five minutes. `api/bin/jobs` runs Solid Queue's CLI. Verify the actual deployed scheduler and worker are alive and their database connections are correct; a YAML entry or direct Rails job test is not production execution evidence.

An authorized operator may run these existing jobs explicitly in the verified environment if the scheduler is interrupted:

```sh
RAILS_ENV=production DATABASE_URL="$BOG_VERIFIED_DATABASE_URL" bin/rails runner 'ChallengeReminderRecoveryJob.perform_now'
RAILS_ENV=production DATABASE_URL="$BOG_VERIFIED_DATABASE_URL" bin/rails runner 'ChallengeSourceLeaseExpiryJob.perform_now'
RAILS_ENV=production DATABASE_URL="$BOG_VERIFIED_DATABASE_URL" bin/rails runner 'FinancialDocumentSourceCleanupRecoveryJob.perform_now'
```

The reminder recovery command can send configured consented email. Keep `REMINDERS_EMAIL_ENABLED=false` for rehearsals and this launch hold; do not run delivery against real recipients without explicit outbound authorization. Email requires the operator flag, verified sender, valid public HTTPS root, configured transport and current participant consent (`api/app/services/challenge_reminders/production_email.rb:10`). Configuring those values is not authorization to activate delivery. No WhatsApp automation exists in this pilot scope.

Monitor aggregate status counts, oldest due age, attempt counts, leases and sanitized error classes; do not print amounts, merchants, feelings, source text, recipients, keys or credentials. Reminders never create check-ins or financial progress. Missing delivery is not evidence that a participant was inactive. In-app recovery fences old lease tokens. SMTP is non-idempotent: unknown delivery must not be blindly retried or marked sent; preserve uncertainty and investigate transport diagnostics within authorized scope. The E02 historical and E08 later 30-person worker rehearsals proved primary in-app outbox recovery with Solid Queue bypassed, not SMTP or production scheduled-job durability.

The source-cleanup outbox lives in the primary database and survives import removal or queue admission failure (`api/app/models/financial_document_source_cleanup.rb:17`). Recovery enqueues due/expired-lease records. On physical-delete failure retain the key and retry state; never manually mark completion or clear the key to quiet an alert. Repeated requests share one obligation; replacement-source protection and lock ordering matter. Storage doubles exercise failures, but actual S3 delete-fault acceptance remains open.

## Source reads, deletion and retention

Participants use authenticated application source reads; grants and deletion/expiry are checked on each new read. Do not hand participant/coach clients a presigned storage GET URL for the challenge viewer. Direct private upload is a separate capability. Clear/reauthorize local previews on identity/revocation changes. Already downloaded copies cannot be recalled.

Use the participant's reviewed source-revoke control, which shows every affected authorized use. It revokes globally and creates durable cleanup while preserving approved structured facts. Another program/coach cannot veto the owner's deletion. Source deletion is distinct from correction/revocation of an approved savings evidence allocation: reviewed immutable financial facts and proof history survive original-byte erasure; a changed approved source/account version can invalidate current proof and requires explicit review. Closed checkpoints remain frozen unless revised. A fully removed import may leave a null import ID/filename in retained proof displays; `source_available=false` is expected. Do not create a replacement source, clear approved evidence or downgrade historical financial truth merely to repair a missing source link.

Source expiry follows the latest explicitly authorized use; joining a program cannot silently extend it. The integrated lease mechanism uses personal challenge end plus 30 days and expiry recovery. The final disclosed retention period, account/structured-history controls, backup handling and provider retention/data-use must still be accepted before invitations. Do not promise that storage deletion erases provider or backup copies on the same schedule.

Private storage configuration uses the existing AWS credential/bucket/region/prefix interfaces in `api/app/services/s3_service.rb:16`. Inspect availability/authorization without displaying values. Use only exact owned QA object keys for fault injection and cleanup, never a bucket-wide delete or prefix guessed from the repository. Keep real originals/oracles outside Git, telemetry and shared fixtures; preserve only sanitized aggregate evidence and local encrypted/private artifacts as authorized.

## Backup and restore

The preserved October 5 rehearsal at `69a28df` quiesced the API, custom-dumped a disposable database and restored into a separate owned database. All 160 public tables, 158 sequences and 7,923 rows matched exact digest checks. It did not restore source bytes/provider backups or production services. Use that as a reproducible local layer, not a promise about production recovery point/time or deletion policy.

For the next authorized rehearsal, reserve separate source/destination QA DBs and a private backup directory, stop only the exact owned writer/API resources, and verify quiescence. Existing PostgreSQL tools can create a custom archive and restore to the empty disposable destination:

```sh
umask 077
pg_dump --format=custom --dbname="$BOG_OWNED_SOURCE_DATABASE_URL" --file="$BOG_PRIVATE_BACKUP_PATH"
pg_restore --no-owner --no-privileges --dbname="$BOG_EMPTY_RESTORE_DATABASE_URL" "$BOG_PRIVATE_BACKUP_PATH"
```

Confirm both URLs by sanitized database/host identity first. A restore must never target the source or an existing preserved database. Do not use `--clean`, schema rollback, truncate or broad cleanup against preexisting data. The private archive may contain sensitive data; never commit/upload it or expose its path as an unauthenticated download.

Verify exact per-table contents and sequence states, approved savings/source/baseline/checkpoint version counts and digests, current heads, allocation capacity and scope guards; reconnect only the owned test application and compare participant projections and revocation/expiry behavior. Record dump SHA, source/restore commits, quiescence, counts and limitations. Separately reconcile any authorized source-object inventory and the chosen retention policy; no provider backup/retention claim follows from DB equality. Drop only the explicitly owned disposable destination and remove only authorized private backup artifacts after evidence is retained. Production backup cadence, encryption/access, recovery targets and retention policy remain operator decisions to verify.

## Launch record and final cleanup

Before invitations record the actual start/calendar, 30-seat capacity, Mel/Leon support coverage, accepted privacy/provider/retention wording, fixed coarse sponsor template, Mel's approved coaching examples, physical phone findings, final matrix execution, current-head repository/reviewer status and exact deployed smoke. Release activation, invitations and outbound notifications require their own authorized action; this document leaves them held.

Every execution phase ends with exact resource cleanup or a named accepted handoff. Do not close user tabs, stop borrowed services, delete shared DBs/storage, or remove a held worktree. The final report identifies each owned resource, disposition and unresolved ownership. This documentation audit started no servers, tabs, workers, DBs, storage objects or external messages.
