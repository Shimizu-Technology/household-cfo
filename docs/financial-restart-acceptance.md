# Financial restart and Mia help acceptance

Starting over replaces practice numbers with an empty current household financial
picture. It is a reviewed household-owner action. It does not delete the account,
household membership, challenge enrollment, approved savings, evidence, optional
card reviews, original uploads, bank credentials, or audit history.

## Participant flow

Ask Mia to reset all practice information, choose Start over in account help, or
open it from chat context. Mia opens the same concrete review. “Everything” after
a reset request must not repeat a clarification loop. Review exact record counts,
the household name, what remains, and what needs a fresh review. Confirm the
financial action separately; shared households require a second acknowledgment.
Canceling changes no financial values.

After confirmation, setup is **not entered**, rather than confirmed zero. Old
income, schedules, debt, accounts, goals, categories, allocations, actuals, and
pending edits cannot contribute to any current or future planning period. Old chat
and private notes remain available for reference; their coaching context is paused.
A note can be edited and saved to explicitly resume it.

Original files remain readable and removable under their existing privacy controls.
Earlier extracted values cannot be applied. Upload a fresh copy for a new review.
Bank connections remain paused until you review Use new bank activity.
That action disables automatic confirmation and stages only newly received activity;
earlier transactions remain read-only history.

## Required verification

1. Exercise ordinary and BOG owners, a shared-household owner, a partner, coach and
   administrator. Only the owner may restart their own household. Check revoked
   membership and changed program context before preview and approval.
2. Populate multiple sources, scheduled raises, future plans, debts, accounts,
   categories, actuals and more than twelve review records. Cancel once, then apply.
   Compare current and future results before and after. Preserve enrollment, savings,
   evidence, optional-card terms, members and immutable history.
3. Race approval with another edit, upload completion, transaction confirmation,
   bank sync, and a second restart. Reject stale generations and changed inventories.
   Simulate a lost approval reply, reload and recover the exact receipt before retry.
   Repeat approval with its original identity without incrementing twice.
4. Keep another tab open and simulate another device restarting. No old reply may
   hydrate into a new picture, and no fresh financial reply may mix with an old
   workspace. Check baseline, sources, Mia edits, transactions, budget and bank data.
5. Request the saved income through Mia after restarting. Missing income is unknown.
   Add a new source through its normal reviewed flow. Earlier chats must not restore
   the practice amounts. Inspect paused files and bank history, then review a fresh
   copy and new bank activity.
6. Inspect 1440px desktop, tablets, 390px and 320px phones, and short landscape
   viewports. Chat context and prompts use one panel at a time. All prompts prepare
   the composer without sending. Closing preserves typed text. Headers and Close
   remain reachable while scrolling; controls have breathing room and keyboard
   focus stays within a modal. Check Guide, Feedback, expanded chat and nested dialogs.

Run the repository's full Rails and frontend gates and inspect real browser evidence.
Viewport checks do not replace physical iPhone/Android and Mel's participant acceptance.
Production smoke tests must not reset real participant records.

## Deployment

Ship the scoped API and additive migrations before publishing the matching frontend.
The migrations retain earlier records and enforce generation boundaries in PostgreSQL.
Once any household restarts, **do not roll back to an API that reads unscoped retained
records**: it would expose the previous financial picture again. Use a forward fix
or maintenance hold. Verify exact API and frontend commit IDs independently.
