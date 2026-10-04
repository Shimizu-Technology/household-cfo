# BOG readiness evidence — October 5, 2026

The pilot remains on launch hold. Implementation and engineering coverage are substantial; the combined participant promise has not passed all 209 acceptance scenarios. The matrix records **2 PASS, 179 NOT RUN and 28 BLOCKED**, with two completed monetary scenarios passing within their stated backend scope. Each row names related assertions or a documented evidence gap, the static commit, partial runtime proof when available, and the remaining execution. This is an audit of evidence, not a newly executed product suite.

The original static repository snapshot is `36100012c01fd2fa9a1011f5cf11f24729177d86`; this update inspects integration `dfffba74e0a3cc1c7e71cc7d72f71ad0717c9e50`. Historical source/test pointers retain their original commit attribution. A named test at that commit is a coverage lead. Its existence does not prove it ran on the final integration head or satisfies an entire browser/provider journey. IMPORT and REVIEW pointers inherited from the source agent retain their original source and ROOT commit attribution rather than pretending their line numbers were tested here.

## Preserved evidence

Private artifact roots below are local worktree paths, not published files. Only sanitized aggregates and hashes are committed. Hashes identify the exact bytes read; if the integration owner reruns a rehearsal, add a new record instead of silently changing an old result.

- **Integration private root:** `/Users/leonshimizu/.codex/worktrees/bog-challenge-integration/household-cfo/`
- **Source private root:** `/Users/leonshimizu/.codex/worktrees/bog-source-accounting/household-cfo/`

| Evidence | Exact artifact and commit | Established | Limits |
|---|---|---|---|
| E00 | Static inspection at `3610001`; matrix names repository paths and lines | Related assertions/source seams, or an explicit gap, for all 209 cases | No test execution in this documentation slice; no blanket PASS |
| E01 | Integration `.codex/qa/http-rehearsal-results-historical.json`; API process `8e48c25`, frontend `f17e392` | 30/30 synthetic actors, 503 real HTTP requests, six concurrent clients, 37.8 seconds; P50 0.4792s/P95 0.7671s/max 1.0916s; sequential 31st enrollment denied; no recorded failures | Synthetic auth, not normal deployed Clerk; local PostgreSQL/laptop, not production sizing; no provider/storage/email work; not 30 simultaneous clients; before later source reprocess/JSON-header changes |
| E02 | Integration `.codex/qa/worker-restart-results-historical.json` and `worker-restart-rehearsal.rb`; owner reports process startup `f17e392` | Two separate actual Rails processes; 30 unique in-app reminder records delivered; one persisted lease recovered, two attempts; approved financial state unchanged | Result JSON has no embedded SHA; process provenance is the owner's report. Solid Queue bypassed. No SMTP. Lease recovery at +3 minutes/backoff delivery by +20 minutes uses a controlled test clock, not measured wall-clock recovery SLA |
| E03 | Integration `.codex/qa/restore-rehearsal-results.json`; `69a28df6aa35688f78e13cbb98b7fe1bb7063488` | API quiesced; custom dump restored to a separate owned disposable PostgreSQL DB; all 160 public tables/158 sequences/7,923 rows match exact digest checks | Local database restore only; source bytes, storage-provider backups, production environment and full deletion/retention policy are excluded |
| E04 | Source `.codex/reports/20261004-import-review-evidence/evidence-map.csv` and README; local native oracle `c9cc249a5defbbd182db244bdfa2f72ea42723d2`; final lineage `8526d79d19227f2d7a11243da6e56e7d372c6443`; source UI `6204d3a` | 34 IMPORT/REVIEW cases mapped individually. Exact local native oracle: 1 test/141 assertions; 934 signed posted rows/33 informational rows/18 account periods; physical-page/date/cents multiplicity and balances. Earlier actual S3/job logs match financial multisets with zero missing/extra and remain unreviewed | Native oracle uses local I/O, no model call; not a merchant/classification/effective-date/funding oracle. Historical S3/job and browser results are older. No real financial approval/economic linking performed. Source map notes historical root concurrency errors; final successful exact-head concurrency evidence must supersede them |
| E05 | Integration `.codex/reports/20261005-combined-live/actual-api-proof-linked-desktop.png`; owner associates combined runtime API `8e48c25`/frontend `f17e392` | Native desktop screenshot visibly shows $100.00 reported and $25.50 supported as a linked subset, synthetic reviewed source and explicit link/revoke controls | Screenshot alone carries no embedded commit; provenance from owner. Actual API, synthetic source/auth; not a real PDF/provider run or physical phone test; no claim that the full mixed-withdrawal scenario passed |

E01/E02 result copies now have `-historical` filenames; their recorded result hashes are unchanged. The E01 historical driver fingerprint below records the earlier audit bytes; its current path has been revised for E07 and no separate old driver copy is claimed. E02/E08 are primary-outbox recovery proofs, with Solid Queue bypassed. E08 result bytes happen to equal E02; the later process provenance is the execution owner's separate report, not something the hash can establish.

## October 5 later executed layers

| Evidence | Exact artifact and commit | Established | Limits |
|---|---|---|---|
| E06 | Integration `.codex/qa/backend-final-full-rails.log`, `backend-final-rubocop.log`, `backend-final-zeitwerk.log`, `backend-final-brakeman.log`, `backend-final-bundler-audit.log`; owner identifies backend `5072fca4417ad87ae1803828e73e8bbf5a318b43` | Full backend suite: 2,552 tests/39,512 assertions, zero failures/errors/skips; 1,033 Ruby files linted without offenses; autoload passed; security/advisory scans report zero warnings/vulnerabilities | Ruby 3.3.7/local disposable PostgreSQL, explicit test DB settings per operator report. Logs do not embed SHA/DB name. Verified Git API tree is `a49d74b52af2f8576f55456ea8eeb11b5a94d189` at both 5072fca and dfffba7. Domain/request assertions passed; no complete browser/provider or human acceptance inferred |
| E07 | Integration `.codex/qa/http-rehearsal-results.json` and `run-http-rehearsal.py`; result identifies `dfffba74e0a3cc1c7e71cc7d72f71ad0717c9e50` | 30/30 synthetic actor workflows; 503 actual HTTP requests, six concurrent clients; 36.91 seconds; P50 0.4735s/P95 0.727s/max 1.0329s; sequential 31st enrollment denied; no recorded failures | Synthetic auth/local PostgreSQL; no live extraction/storage/email, physical phones or 30 simultaneous workflows. Some targets postponed/custom, some optional cards/manual purchases/withdrawals. Does not complete OPS-14 peak/provider cost/queue acceptance |
| E08 | Integration `.codex/qa/worker-restart-results.json`, `final-worker-claim.log`, `final-worker-recover.log`, `worker-restart-rehearsal.rb`; owner reports both later Rails processes at dfffba7 | 30 unique primary-outbox in-app reminder records delivered; interrupted lease recovered with two attempts; financial state unchanged; no email | JSON contains no SHA and equals historical E02 bytes; owner report supplies process identity. Controlled clock +3 minutes/+20 minutes. Solid Queue bypassed; no production scheduler/SMTP/SLA claim |
| E09 | Integration `.codex/reports/20261005-combined-live/` native screenshots below; owner reports API startup `46f5725`, frontend dfffba7 for these questions | Four native actual-API questions per execution owner: optional cards/full budget; approved $75 progress/$300 target/$0.50 evidence included as a subset; protect essentials/no savings or loan-eligibility guarantee; employer records remain private and sharing optional. Three response screenshots directly show the numerical, essentials and privacy answers. Optional-card screenshot shows approved fictional $300 balance, unknown APR/minimum/due, no eligible single-APR avalanche | Synthetic participant/source/auth, desktop Chrome including narrow viewport. Native viewport is not a physical phone. The owner also records approved withdrawal $100→$75 and supported $25.50→$0.50; the visible after-state supports this result, not every intermediate action. Deterministic savings answers do not prove live model behavior, Mel's approved voice, all distress examples or sponsor endpoint security |
| E10 | Integration `.codex/qa/empty-file-boundary-results.json` and `empty-file-rejected-mobile.png`; result identifies API/frontend dfffba7 | PASS for zero-byte PDF: native 320-pixel composer shows a clear filename-specific rejection, no attachment/Send disabled per owner; actual presign returns 422 `Uploaded file is empty`, no upload URL, import IDs unchanged | CSV/whitespace and separate multipart route not executed; corrupt/password-protected nonempty PDFs excluded. Overall IMPORT-11 stays NOT RUN for remaining variants; legacy empty extraction results do not contradict this boundary |
| E11 | Integration `.codex/qa/frozen-browser-full-dfffba7.log`, inspected while running; candidate dfffba7 | The synthetic browser batch includes successful narrow flows and visible failures/timeouts in pilot-hardening daily flows | Pending/failing batch, no final browser PASS. Root's repair and exact-head rerun remain required. Mock browser cases are separate from E09/E10 actual-API computer use and do not establish real deployed Clerk/provider/phone behavior |
| E12 | Integration `.codex/qa/participant-native-export-result.json`; owner identifies frontend 598d00e/API product bytes dfffba7 | Actual macOS Downloads file independently verified after native export: reported 7,500 cents, supported 50 cents, optional reflections excluded. Export bytes recorded SHA256 `1035341f3c76b5fe7a15693654492971b32b34c38051fe1a5177cebd84697ed8` | Synthetic participant; browser download event timed out but the operator verified the real file. No sponsor CSV, reflection opt-in, normal deployed auth or complete personal-export acceptance claim |
| E13 | Integration `coach-no-private-sharing-desktop.png` and `second-program-private-state-cleared-desktop.png`; owner reports frontend dc11914e/API startup dfffba7 | Ungranted coach screenshot shows plan/daily completion metadata and “Challenge money summary is private”; no private values, sources, chats or feelings visible. Owner records close→zero panels/reopen→one after distinct React key fix, and program switch→zero progress panels/original→$75/$300/$0.50/second→zero | Native actual local API with synthetic identities. dc11914e repair has five focused passing unit tests per owner, not a final browser gate. Program switching is not logout/account switching; screenshot is an after-state rather than all intermediate actions |
| E14 | Parallel-guard worktree `.codex/qa/full-rails-parallel.log`, `full-rubocop.log`, `brakeman.log`, `zeitwerk.log`; commit `5c2cb7e75d4c09b8666efe44345497ff2647c229` | Two-worker full backend: 2,557 tests/39,537 assertions, zero failures/errors/skips in 314.611 seconds; 1,035-file lint, autoload and security checks passed. Exact whole-tree equality verified against backend PR commit 38a5267: `d40d05047aa64eb9a1c469a707438d43e4a9d5e3` | Ruby 3.3.7, owned `bog_parallel_guards_test` and exact `_0`/`_1` worker DBs, explicit matching test variables; handoff reports all three dropped. Extends E06 after five guard tests, not a provider, UI, human or CI/reviewer proof |
| E15 | Integration `second-program-crossed-chat-before-fix.png`; root reports API startup dfffba7/frontend dc11914e | FAIL: the second program correctly cleared Home progress, but Ask Mia refilled the original program chat. Existing household/user-global session selection does not provide program isolation | Material release blocker. Root delegated central program-scoped session selection, scoped status/idempotency and migration 20261004320000; fix, gates and native rerun pending. Not a claim of another household's records being disclosed; it is a failure of program-private chat isolation |

These later layers do not replace E01–E05. SAVE-15 and SAVE-26 are PASS because their exact preconditions, approval/evaluation actions and monetary outcomes were executed in E06/E14. They do not require a provider or human decision to establish those numerical results. IMPORT-11 changes from BLOCKED to NOT RUN because its asserted policy contradiction was false; remaining variants are unexecuted. Separate matrix columns identify **74 scoped backend assertion PASS records, 8 scoped native UI PASS records and 1 native UI FAIL record**, not additional complete scenarios. These columns overlap. PRIV-14 is now BLOCKED by E15: passing Home clearing does not establish chat isolation. E15 supersedes any broad interpretation of E13's program-switch result. None of the 209 cases has live-provider or human-layer completion established by this audit; for a pure numerical case those layers are unnecessary, while broader cases still require their declared layers. [Mel's review packet](mel-acceptance-packet.md) contains the concrete decisions and walkthrough still required.

### Artifact fingerprints

| Artifact | SHA256 |
|---|---|
| E01 result | `367990f54dac7916b621ea14cdfd3b840df74da0b90fe69f6e0e641cebf33f19` |
| E01 historical driver fingerprint (earlier audit; current file changed) | `ad31b1822da2bf11bb8e611b4bf8ea840d27e2500b53751b588705ffe5d4f34a` |
| E02 result | `b426d60bb7e96d2caacfc598a0da1ca41595b64d6fc827cca3194ddc837c8f8d` |
| E02 driver | `f969aef4d6c051db39ab782b2025d158be5c691cd8db5785f3cf6242ac6a7fe0` |
| E03 result | `851d219cbe7ee56e830329bb0ea3d3c370246b5798f6de0edc3510323611c241` |
| E03 custom dump, as recorded by restore result | `b4e39def8fb5a3f22a3b653d605012a6eb51530947a02018784340d1a4b93ec5` |
| E04 source map | `c42fc9bc76e69282b8b239a0fc7f230443acfc50c484fbfac70fdc55f6b880d1` |
| E04 source README | `13a606d21b76fd6beb780e6990c6dd62913224ff8e2df94a38b3dd843772cfdc` |
| E04 historical native multiset log | `7f29b234da1c5ed103b01d114820778b45f8a751ecb35404f2c883e6608947f7` |
| E04 historical native job log | `341402965b850ba0fbe4067db17168f461ed587768f2d00d64b900e9bca982f1` |
| E04 exact-head native oracle log | `8d0b825b0d3905d4cd8317006affc1baedb2bc28e43023611132072e57d96037` |
| E04 historical source browser notes | `40c7c62b861545b2f662706a9fc1b0f2cddfde6465c5123ff46c1e0466e65962` |
| E05 screenshot | `9b4054b6f223f1c890eb98b429756f91574f6c2faeead778499ebbf4d5c97d48` |


### Later artifact fingerprints

| Integration-private artifact | SHA256 |
|---|---|
| `.codex/qa/backend-final-full-rails.log` | `c9b364300951d8827291e4134f15384904d99393440e9ef31bcc2671f5887cab` |
| `.codex/qa/backend-final-rubocop.log` | `0673f8eccd72baa2e0e46ada06ff55855a350251b3dcf23fcc91348c61815685` |
| `.codex/qa/backend-final-zeitwerk.log` | `b72900d20b063373acc32103fa91dc57beae4caa9edc2adc0b023fa4d6b3e541` |
| `.codex/qa/backend-final-brakeman.log` | `a08c1c477f82d768918c74a7bbb8ee8cfdd158cf6f966a48d9ebc03d12c2793c` |
| `.codex/qa/backend-final-bundler-audit.log` | `99eb30345b3c2c01f4c970600f7c176d8a2ea8863d0f926c4f53938941e7f0d2` |
| `.codex/qa/http-rehearsal-results.json` | `6d1de34baaba6affc06b16a16257fc382bf07ea84404f1f035b032775b36fd3f` |
| `.codex/qa/run-http-rehearsal.py` | `a2de99d880627a09719478625cc312caa073c70bfc7a17d8ac92b8cf70a8bf3b` |
| `.codex/qa/worker-restart-results.json` | `b426d60bb7e96d2caacfc598a0da1ca41595b64d6fc827cca3194ddc837c8f8d` |
| `.codex/qa/empty-file-boundary-results.json` | `ea1ca5c498f9937d3f8be8693d4bf782d763626319f472c3687029afa13eb2a1` |
| `.codex/reports/20261005-combined-live/mia-approved-ledger-subset-mobile.png` | `7a1c027051b46e3e16a6dbd54c7c8e003e263a7d657f1336aecd147ff21cdb69` |
| `.codex/reports/20261005-combined-live/mia-essentials-guarantee-mobile.png` | `d00f0ae73e0e466c0232857fe4a284c9a4d45f489a4819305515065b0baad23a` |
| `.codex/reports/20261005-combined-live/mia-employer-privacy-mobile.png` | `e3dff9e5008acdf61a462ec47e42677d93110d7ece6f2aaff62e173e93e939ea` |
| `.codex/reports/20261005-combined-live/mia-desktop.png` | `f907f6cd6bd236ba32b25521fe298b39ea739c4f21eb0a018a237e58ac69db5f` |
| `.codex/reports/20261005-combined-live/optional-debt-approved-mobile.png` | `5273d71c09c693f6e8df8773232fd27b5e6f484f342deb86601fa4fc01a5418a` |
| `.codex/reports/20261005-combined-live/empty-file-rejected-mobile.png` | `b4bcf574075771cdcb74bad4673fb2ad5d93bf9107ea9328011539dcf45f0568` |
| `.codex/qa/participant-native-export-result.json` | `ebebb6451e5b6ccabacf7445d5a1561844dabad94dfaa2e023fb7d0a54d8c057` |
| `.codex/reports/20261005-combined-live/coach-no-private-sharing-desktop.png` | `c2d11790f34ff075ab20b0339d5836e0691f2588accf3eadc583e50f7b9399ce` |
| `.codex/reports/20261005-combined-live/second-program-private-state-cleared-desktop.png` | `81b0b4a47df45a5a4e32cf5ff4305d2bc82026db221a7014c6a5e06765d8b23b` |

E14 private root: `/Users/leonshimizu/.codex/worktrees/bog-parallel-db-guards/household-cfo/`.

| E14 private artifact | SHA256 |
| --- | --- |
| `.codex/qa/full-rails-parallel.log` | `6c432e472cb9991326822d01c0a5774673388c279dd5a9138a74cf98428649b7` |
| `.codex/qa/full-rubocop.log` | `e9f85fc04017843117d98227e56a97cde7d8cecdbe5fb7b3420501c026b72146` |
| `.codex/qa/brakeman.log` | `d3d5b269f0e0a3222d1ec8ae32faaf694f19e7676206d5618e880c8117af0459` |
| `.codex/qa/zeitwerk.log` | `b72900d20b063373acc32103fa91dc57beae4caa9edc2adc0b023fa4d6b3e541` |

E09/E13 operator provenance is also captured in integration `.codex/qa/bounded-native-qa-results.json`, inspected SHA256 `399fc98973cb5bc9c2790392ac0f6fed32b8917b552da2e814ecc20c7ccd69b5`. A private snapshot is retained in the documentation worktree; the mutable root artifact must not silently replace this record. E15 screenshot SHA256: `9d43b5bafe32aac30c9bdd14b1e21d551d2cb8d4cf33d5dd12ec4586d927806a`.

## What remains before launch

The matrix is the detailed record. These holds summarize decisions and missing layers that a green suite cannot settle:

- **Human acceptance:** actual start date, voluntary participation/target explanation, Mel's authored persona and teaching examples, distress/essential-spending responses, support coverage and escalation contact. November 1 is still a fixture/proposed schedule. Mel coaches; Leon owns technical operations. Coverage hours and response promises remain unsettled.
- **Privacy and provider policy:** final consent and source-use/retention notice, shared-source expiry, structured-history/account policy, backup retention and provider data-use/deletion settings. The proposed 30-day post-challenge source expiry is not a signed provider deletion guarantee. Previously downloaded copies cannot be recalled.
- **Real integrations:** current-head normal deployed Clerk login/invitation/session/revocation, actual scheduled queue jobs, private source storage and delete failures, fallback provider accuracy/failure recovery, email consent plus verified transport only if included. No invitation or outbound delivery is authorized by these artifacts.
- **Devices and accessibility:** real iPhone Safari and Android Chrome, keyboard/safe areas/app switching, network interruption, enlarged text and VoiceOver/TalkBack. Desktop emulation and native desktop viewport overrides are useful partial layers.
- **Complete journeys:** all named six-real-file classifications/economic links/approved baseline effects, fictional issuer corpus and derivatives, explicit 50-row bulk semantics, >500 cross-year review, corrected baseline/checkpoint replay, full coach/sponsor revocation/inference boundaries and final service expectations.
- **Release:** current exact-head full gates, material reviewer findings resolved, S04–09 integration review and CI, immutable accepted BOG release, exact-commit deployed smoke and a repeat of changed rehearsal paths. E06 proves the backend gate; E11 leaves the combined browser gate unresolved. S03 PR148 deployment is separately recorded at 451c250 and does not deploy the new S04–09 integration. Root reports API PR149 at 38a5267 with CI pending and merge HOLD for E15. The current parallel backend gate predates this discovery and cannot prove its repair. CodeRabbit skipped its 251-file review because of the file limit and unavailable credits; this is not a clean review.

MIA behavioral cases require special care: `api/app/services/savings_challenge/coach_answerer.rb:9` routes deterministic answers. `api/test/controllers/api_v1_savings_mia_controller_test.rb:18` verifies approved numerical/context boundaries, not Mel's approval or a live model's voice. IMPORT-11 no longer has a demonstrated policy conflict: zero-byte upload rejection is separate from a nonempty source that extracts no rows. E10 passes the tested zero-byte PDF composer/presign boundary. The full case remains NOT RUN because CSV/whitespace and the separate multipart path were not executed; corrupt/password-protected nonempty PDFs are separate cases. A reviewed zero-activity statement must not be rejected solely because it contains no financial movements.

A narrow domain or local rehearsal result may be PASS within its stated layer. The full acceptance status changes only after its actual preconditions, actions and expected outcome are executed on the recorded release/environment. Removing an optional feature requires explicit scope/UI/documentation changes and a preserved REMOVED WITH SCOPE CHANGE record; it cannot erase core savings/privacy requirements.
