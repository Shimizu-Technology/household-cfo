# Durable document extraction dispatch

Private source registration and manual reprocessing now store a `FinancialDocumentExtractionDispatch` in the primary database in the same transaction as the source/status change. Queue admission happens afterward. Rejected or uncertain admission keeps the intent pending; a successful upload keeps its existing HTTP/JSON response.

The dispatch holds a source digest, generation, safe error code and leases, rather than filenames, source keys or provider output. Manual reprocessing starts a new generation. Jobs carry the import, dispatch and generation IDs; old queued jobs remain compatible through their original single-import argument. The import lock precedes the dispatch lock. Concurrent admissions share one lease, and provider publication also checks the current generation, source digest and authoritative extraction attempt.

`FinancialDocumentExtractionRecoveryJob` scans at most 100 missing legacy intents and 100 due intents per invocation. Rows inserted during backfill stop qualifying for the next backfill, so queue failures cannot indefinitely block later uploads. Queue admission leases expire after 15 minutes. Processing leases expire after 15 minutes without progress. The extractor renews the matching attempt at batch boundaries and before/after provider requests; an old worker cannot renew a replacement generation. Recovery cannot prevent duplicate external provider cost if a remote request survives a stopped local worker, but only the authoritative result can create review facts. Facts remain pending participant review.

Recovery uses the persisted source key, deletion state and explicit source-use expiry/revocation. It does not use an S3 HEAD result as proof that the source was deleted. Loss of source permission or changed source cancels the old dispatch and shows a safe failed-import explanation while preserving prior structured facts. A real storage/provider failure is an explicit failed extraction, requiring deliberate reprocessing instead of automatic paid-provider retries. Restoring access allows the ordinary manual reprocess path to start a new generation.

Production recurring configuration requests a sweep every five minutes. Actual scheduler operation must be verified in deployment. If the queue/scheduler was lost or stopped, an operator can run a bounded sweep directly against the primary database:

```sh
RAILS_ENV=production bin/rails document_extraction:recover
```

Run again as needed for a backlog larger than 100. Queue admission failures back off from 30 seconds to at most one hour. Deleting an import nullifies its dispatch reference; recovery cancels the orphan without provider work. Neither recovery nor manual reprocessing discards immutable extracted revisions or previously reviewed financial versions.

Synthetic tests cover atomic rollback, primary commit before queue admission, rejected/uncertain admission, expired admission leases, killed provider work, long extraction heartbeats, superseded generations, local source expiry/revocation/deletion, changed-source batch starvation, legacy backfill, safe error handling and separate PostgreSQL admission sessions. These tests do not establish production provider or scheduler availability.
