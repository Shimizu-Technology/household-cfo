# Challenge conversation boundaries

Savings challenge conversations belong to one household, participant and cohort. `Mia::ChatSessionScope` selects that session for history, workspace data, new messages, request replay, review status messages and clearing. It authorizes the participant's current membership and sealed savings runtime. Writes reauthorize under the household lock and reject a runtime release change while a response is being prepared.

Legacy household conversations retain their original session IDs and the household/user uniqueness rule when no savings challenge is selected. Ordinary household program releases continue using that legacy session. Challenge sessions have a separate household/user/cohort unique index; a missing program session never falls back to household history.

Message cohort and release attribution must match the challenge session. PostgreSQL guards prevent changing session actor/program identity or moving an existing message into another session, and reject unsealed or mismatched challenge messages. Selected chat sharing and candidate lists require the enrollment's exact participant/program session as well as the existing exact-record consent.

## Upgrade behavior

Migration `20261004320000` creates program sessions only for historical messages with an explicit matching cohort and sealed savings release. Message IDs, timestamps, attachments and citations remain intact. Household messages, unattributed rows and ordinary household release messages remain in the original session.

A completed cached request moves only if both actual message IDs, contents, cohort/release attribution and response structure prove that program. Cached budget, spending or action payloads are excluded. Mixed summaries, active topics, evidence context, processing requests and unprovable responses remain in the legacy session; the migration does not invent program attribution.

Retrying an unprovable old request key from a challenge returns HTTP 409, `code: mia_request_scope_unknown`, `status: unknown`, without the old payload. It does not assert that the old request failed, committed or disappeared. Review the relevant records before submitting a new request. New program requests use separate keys per session, so an identical key in another program cannot replay the first program's result.

Clearing a challenge clears only that session's messages, requests and conversation state. Existing processing-request protection remains. Hold or revoked access blocks ordinary reads, writes, replay and clearing. Emergency guidance remains available without attachments or private context: when a challenge is unavailable it returns `conversation_persisted: false` and nil message IDs, without creating a session, request or message. Legacy emergency guidance keeps its existing contract.

Rollback refuses to combine program conversations and requests into household history. `ChallengeChatSchemaDumper` preserves the guards when Rails creates a test worker or loads the schema.

## Verification scope

`ApiV1MiaProgramScopeTest` exercises real authenticated controller requests against two sealed synthetic programs: fresh-program history/workspace isolation, independent request replay, clearing, hold, late membership removal, narrator history selection, pagination, exact sharing and legacy household behavior. Narrator spies verify context and late authorization; they are not provider or browser evidence.

`ScopeChallengeChatSessionsTest` runs the actual upgrade SQL against attributed and ambiguous synthetic history, checks stable IDs and request movement, and tests direct SQL guards. The integration owner must still repeat the native UI discovery and upgrade the named live QA database before claiming that user flow verified. No real participant history, provider response or source document is used by these tests.
