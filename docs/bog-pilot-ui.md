# BOG pilot interface and acceptance checks

The BOG pilot is planned for 30 people, with a goal of saving $500 over a 90-day challenge. A target is a plan, not proof that money was saved. Participants review and approve their own entries; statement imports do not automatically become savings.

## Participant experience

Choose the BOG program in the program selector. The choice survives a reload, but the server still checks program membership before loading private information. The main navigation is **Today**, **Savings**, **Mia**, **Statements**, and **Tools**.

- **Today** captures spending, an explicit no-spend report, and optional feelings. Unknown spending must remain unknown until the participant supplies an answer. Proposed changes require a separate review and approval.
- **Savings** shows the participant-reported reserve, the evidence-supported subset, the accepted target, personal challenge dates, and pending review counts. The evidence-supported subset is part of the reserve, not an additional amount. Records, corrections, and deeper tools open on demand.
- **Mia** keeps the conversation and composer visible. Context and help remain available in a compact disclosure. Suggested prompts fill the composer without sending. Mia's proposals do not silently change approved numbers.
- **Statements** contains uploads, account identification, source-row review, and coverage checks. Account review requires an explicit decision and note. Approving an account identity does not approve its transactions. Review duplicate matches and incomplete coverage before accepting extracted facts.
- **Tools** contains optional Review, Budget, My Profile, and Wealth screens. Detailed income, accounts, goals, debt, bank connections, and saved summaries remain available behind disclosures. Phone budget editing shows one month at a time and preserves edits when changing the edit month.

**Account & help** contains the guide, privacy controls, and **Report a problem**. A new pilot report requires explicit permission for technical support to read that report and its optional screenshot. This does not grant access to statements, chat, feelings, or household financial records. Participants can withdraw future support access from their report history. Withdrawal cannot recall material already read or downloaded; a previously issued private screenshot link can remain valid for up to five minutes. Reports and screenshots should contain workflow details rather than financial values or private conversations.

The private challenge export defaults to a readable HTML record that can be printed or saved as PDF from a browser. Structured JSON remains an option. Feelings are excluded by default; original statements, chat, pending proposals, and other participants are excluded. Downloaded copies cannot be recalled.

## Coach and admin experience

Open **Tools → Coach Studio** as a coach. **Daily coaching** is the starting view. Group access lists ten people per page; search covers the complete loaded roster. Assistant configuration follows draft, sources, evaluation and publishing, history, and assignment stages. Publishing and rollout retain their readiness gates. A saved draft is not a published assistant.

Open **Tools → Admin** as an admin. The console has Participants, Cohorts, Support, Programs, and Bank health areas. Participant rows are collapsed and paged in groups of fifteen. Unsaved edits survive paging, saving a different participant, or resending an invitation. Explicit refresh asks before discarding edits. Mutations cannot overlap. Admin support includes only reports with available support access; it does not expose private financial rows.

## Checks before inviting the cohort

Use fictional data for destructive or approval tests. Run these with an invited participant, coach, and admin on a desktop and a physical phone:

1. Sign in with the invited email. Confirm the right role and program, reload, and check that another participant's information is inaccessible. Test a revoked membership and switching accounts on a shared device.
2. Complete Today with unknown spending, no spending, one purchase, multiple purchases, and an existing imported purchase. Save, review, approve, retry a failed response, and verify there is no duplicate approved fact.
3. Upload a checking statement and a credit-card statement. Review account details, balances, rows, coverage, duplicate periods, and corrected extraction. Keep unsupported or uncertain details pending. Confirm nothing changes before approval.
4. Create and correct a savings entry. Compare reported reserve, evidence-supported subset, pending proposals, excluded money sources, withdrawals, and exported records. Check personal day-30, day-60, and day-90 dates.
5. Ask Mia a question and request a change. Inspect the draft, cancel it, approve a valid draft, and reject a stale draft after a manual change. On a phone, verify the real keyboard, attachments, multiline input, and send control remain usable.
6. Test optional profile and budget controls. Open a collapsed correction target, edit a month, switch the edit month, cancel, and confirm approved values remain unchanged.
7. Submit a fictional technical report with explicit consent. Confirm it appears in admin support, mark it reviewed, withdraw access, and confirm it disappears there. Try closing the dialog during a request and reopening it.
8. Test the complete 30-person coach/admin roster, filtering, paging, unrelated unsaved edits, failed saves, and invitation delivery. Sending a real invitation is an operational action, not a visual QA step.

Automated and local browser checks do not replace Mel's review of coaching content, an actual invited-account rehearsal, physical-device keyboard testing, or provider-backed statement and recovery checks. Record those results separately before starting the cohort.
