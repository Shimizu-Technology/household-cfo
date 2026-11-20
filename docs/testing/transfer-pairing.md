# Own-account transfers and person payments (B7)

## Context and acceptance

Household CFO participants upload statements, identify their accounts, and approve source lines. Budget counts categorized approved purchases; Mia reads approved source heads. Money moved between their own accounts counts as neither spending nor income. An unpaired outgoing person payment needs an explicit ownership answer. Someone else means Family support, protected from cut suggestions. An explicit category choice must survive the line form.

This review-fix round starts from `a05d3c52f286fb8433e5df5cf44b17a124b79837`, based on main `80b466433111bd4f81936c3f5a7f06d7b978c8b8`. That base includes receipt tenders (#337), confirmed-purchase questions (#340), and per-account CSV directions (#338). Sources: `ParticipantPlan`, `LineApprover`, `TransferPairs`, `SpreadsheetSignAnswer`, `ConfirmedPurchaseMatch`, `StructuredSpreadsheetExtractor`, and the fictional Talun manifest. No private Brain Dump or production data was accessed.

Required agent-executed affected-flow scenarios:

1. Merchant and bill payments retain their category choices: PAYPAL *EBAY.COM, PAYPAL *NETFLIX.COM, and Payment to Guam Power Authority. Explicit categories on ambiguous person wording also survive.
2. Card/loan payments retain their own question. Payment to Chase card ending 1234 is recognized in a native CSV and contributes no spending when confirmed as a card payment.
3. A Venmo bank purchase matching an already-confirmed purchase asks Same purchase first. Neither a person answer nor a distinct source-overlap answer bypasses that guard.
4. A Zelle movement can be explicitly paired with an opposing movement on another reviewed account. Unpairing reopens ownership for the outgoing person side and the normal transfer question for the other side. The rejected pair is not immediately offered again.
5. Pairing cannot approve any line in a revision with answerable file-level or per-account sign questions. A multi-account CSV with one unanswered account retains that question.
6. Pair prompts show the counterpart description, account, date, and amount. Incoming person-worded money is not offered as a transfer pair.
7. Both scorecard views can review a proposed pair separately when the counterpart is not an own transfer in the answer key, including an unmapped answer-only proposal.

## Implementation

Review has its own person-payment detector; it no longer borrows the broader cut-protection regex. Known merchant domains and billers are excluded; ambiguous Payment to wording still asks. Debt payments bypass the person path. A participant's chosen category takes priority over the Family support form default.

Confirmed-purchase matches take precedence over person/source-duplicate questions. A distinct source overlap associated with a sent-to-someone answer does not waive the confirmed-purchase guard. Pairing is explicit, unique in both directions, within three days, and requires distinct reviewed accounts. Confirming an outgoing person purchase as an own-account pair saves it as a transfer, not as spending. Approved purchase counterparts are never rewritten.

Unpairing appends versions marked for renewed review. They continue to contribute no spending or income while unanswered. No migration or deployment-time backfill changes existing approved records. Incoming person payments remain outside automatic pair suggestions. Open sign-question revisions are computed once per plan, rather than re-reading all their rows for every candidate.

## Verification record — November 21, 2026

Evidence and full logs: `/Users/agent/work/hcfo-evidence/fix-transfer-pairing-r2/`.

- Regression proof: loading the original implementation from `a05d3c52` against the new selected tests produced 8 failures in 12 tests, including merchant detection/category preservation, pair descriptions, incoming person money, simulator separate review, confirmed-purchase precedence/guard, and native card wording. The fixed related run passes 115 tests / 798 assertions.
- Real local build: API 3427, static Vite preview 5427, test authentication enabled in a development-mode compiled bundle, fictional fixtures only. Required Chromium widths: 1366 and 390; pair/unpair also checks 320. This is browser resizing, not physical-device or Safari acceptance.
- Saved outcomes: July actual $35 / pending $0 after explicit pair, unpair, own-account and someone-else answers; Mia reports $35. October actual $180.98: three explicitly categorized purchases ($45.99 + $19.99 + $75) plus the already-confirmed $40 Venmo purchase. The $500 card payment and matched Venmo bank line add nothing. Category choices and questions are checked at both required widths.
- Browser evidence: `{desktop,phone,compact}-{pair,unpaired-person-question,person-question}-final.png`, `{1366,390}-merchant-card-purchase-{questions,saved}.png`. These show the real local API journey, not mock approvals.
- Real local-stack gate: all 4 desktop scenarios pass against the compiled local build; the pair and merchant scenarios also exercise both required browser widths. The affected mocked browser specs (pair/person and receipt tender) pass 2/2 on desktop Chrome with unique port 5527.
- Full Rails suite ran once, serial: 5,597 tests / 83,188 assertions, one failure against the pre-regeneration scorecard baseline, no errors/skips. After Runner regeneration, the final related and scorecard suites pass 132 tests / 877 assertions, including that previously failing test. The whole suite was not repeated after baseline regeneration. All 2,134 web tests (228 files), TypeScript, eslint, production build, Rubocop (1,497 files), and Brakeman pass. The first web run had one unrelated recovery-test timeout; the retry and final run pass. Impeccable's advisory UI scan has no findings.
- Initial browser attempts exposed fixture/setup and locator issues; retained logs distinguish them from passing acceptance runs. The final complete local-stack run passes on fresh data. Final resource cleanup and the two post-regeneration `RATCHET=1` runs are recorded in PR #339 and the worker report.

## Scorecard baseline override

Both baselines were regenerated by `Scorecard::Runner`, never by editing metrics. Against the rebased PR baselines, the fast report changes 40 JSON paths and the full-year report changes 160. Every changed path is a `questions_by_kind` or `decisions_by_kind` counter: the narrower review detector replaces person questions on ordinary transfer descriptions and source copies with transfer/duplicate questions.

Spending, income, category errors, double counts, coverage, receipt results, correction diagnostics, decision totals, and transfer leakage are unchanged. Full-year decisions remain 692 careful / 676 answers-only; fast decisions remain 82 / 80. Full-year spending remains $44,242.95 / $44,278.69, income $91,263.50 in both views, double counts 0 / 2, and own-transfer spending/income leakage $0. Fast spending remains $6,406.23 in both views, income $13,563, double counts 0 / 0, and leakage $0. The annual decision target remains unmet; the known answers-only $35.74 spending error and two double counts remain visible.

## Limits and ownership

No paid service, live model, production deployment, or production data repair was used. Deploy previews stay off. WebKit cannot start on this Mac mini without a screen session; physical Safari is not verified. The lead reviews and merges #339. The separate C2 branch and `/Users/agent/work/household-cfo-b` are outside this task. Task-owned processes, browser tabs, and databases must be cleaned before handback; the unmerged branch and clone remain for the lead.
