# B5 cash drawdowns: round 4 acceptance

Household CFO helps a household review statement lines and confirmed purchases, then uses those saved answers in Budget, spending reports, and Mia. This fix follows decision 3: cash counts when withdrawn; naming a purchase paid from that cash moves categories and adds no spending. B4's “Same purchase” saves a bank line as a match to a purchase that already counts.

Context: PR #342, base `80b466433`, takeover head `e6abf8101`, November 21, 2026. Sources: the PR's decision and review history, `CashPayment`, `CashDrawdowns`, source-review `Domain`, and the API cash-drawdown regression suite. All fixtures are fictional. No paid services are used.

## Required scenarios (agent executed)

1. $100 withdrawal + linked $40 lunch: $100. Save a $40 bank line as the same purchase: $140. Keep the original cash declaration, remove the withdrawal link, and audit which card line answers the cash question. While the match is current, Home and Review ask no cash question.
2. Re-review that line as Different purchase and categorize it: $180 until she answers the lunch's renewed cash question. Nothing is silently linked. Offer the previous withdrawal first when eligible. Yes: $140 ($60 Cash, $80 Dining). Assert each state independently in Budget, spending report, spending analyzer, and Mia's month answer.
3. Approved statement records cannot be deleted or reprocessed through the public endpoints (422). Removing only the original uploaded file retains approved financial evidence. If the matching statement is outside the current financial picture, its historical match no longer answers the purchase's cash question: the unlinked lunch and original withdrawal total $140; explicitly choosing the withdrawal returns $100. The regression models the historical import boundary directly. A whole-household financial restart also retires the old purchase itself; this does not promise to carry old purchases into a new picture.
4. A withdrawal reduced from $100 to $30 leaves a $40 lunch $10 short. “Count the rest on its own” caps the commitment at $30. Restoring the withdrawal to $100 gives $110 spending, preserving that $10 answer. Repeating a saved partial-withdrawal answer succeeds without another change.
5. A prepared purchase update cannot overwrite a newer cash declaration. Negated cash wording creates no cash mark. Pending and confirmed question surfaces state partial coverage accurately.
6. A cash answer invalidates cached plans for other years. Cash answers remain disabled while Mia is replying. These are exercised through the rendered App in browser regressions.
7. Import cards share a prepared drawdown calculation. The scorecard finds an eligible withdrawal beyond the offered three, skips ineligible copies, and raises rather than silently substituting other cash for a named but unavailable withdrawal.

## UI evidence and limits

Compiled local QA assets served on port 5428 with the real isolated Rails API on 3428. The build enables the existing development-only fictional sign-in; the normal production build is verified separately. The undo fixture showed $180 and one Paid with cash question at 1366×900 and 390×844. Tapping Yes on the phone saved $140 and removed the question. No horizontal overflow or external requests. Screenshots and execution log retained by the implementation worker in `/tmp/b5-cash-{desktop,phone}.png` and `/tmp/b5-cash-browser.log`.

The five existing real-API local-stack tests also pass (desktop and compact Chromium). Production authentication deliberately blocks fictional sign-in; the first attempt against production-mode assets was stopped and repeated with the compiled QA build. WebKit and physical-device Safari were not run on this host. Production was not changed. The stack was reset and its database dropped after QA.

The shared-guidance freshness helper could not run because this host lacks `~/.config/shimizu-technology/agent-context.json`. Relevant installed skills resolve to `~/Shared-Guidance/skills` and were read directly. This is a host setup gap, not an application gate failure.

## Automated gate

- Full Rails suite, serial: 5,622 runs / 83,704 assertions, zero failures, errors, or skips (19m18s).
- Related Rails: 52 explicitly selected files, 669 runs / 5,428 assertions, zero failures, errors, or skips.
- Final focused Rails: 46 runs / 754 assertions; the added card-marker assertions then passed separately (1 run / 33 assertions). The final focused run also covers the simulator's ineligible-copy hardening and approved-statement reprocess guard, finalized after the broad run started.
- Both offline scorecards passed `RATCHET=1`. Complete JSON equals the committed baselines: fast 81 decisions; full year 683 decisions. No baselines changed.
- Rubocop: 1,501 files, no offenses. Brakeman: no warnings.
- Web: `npm ci`, TypeScript build, eslint, production build; 229 Vitest files / 2,144 tests passed. Generated SEO files restored. Two new rendered-App Chromium regressions passed. Impeccable advisory scan: no findings.
- Real API with compiled local QA assets: five existing scenarios passed, plus the cash-undo acceptance above at desktop and phone widths.

Owned test databases and local-stack database were dropped. The worktree remains on `b5-r4` for the lead; the PR is held for review and merge by the lead.
