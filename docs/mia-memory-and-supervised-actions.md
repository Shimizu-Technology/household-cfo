# Mia Memory and supervised action drafts

Updated: 2026-07-09

PR #32 has now merged the supervised action-draft scope in this document. The remaining next direction is the Mia Memory discovery and visible/user-controlled MVP described below. See `docs/current-state.md` for canonical implementation status.

## Why this exists

Mrs. Mel's strongest remaining feedback is that the **transaction loop** and **conversation loop** are the core product. PR #29-#31 gave Household CFO the real foundation:

- annual budgets and categories,
- confirmed actuals vs pending drafts,
- receipt/statement/document extraction,
- matching/reconciliation,
- Mia narration from Rails-approved packets,
- voice input with editable transcript,
- evals for real-world prompts.

The next step is not to make Mia a generic autonomous bot. The next step is to make Mia a **memory-aware, supervised financial operations assistant**.

Good product promise:

> Mia remembers your household rhythm, helps you adjust the plan, and prepares changes for you to approve.

Bad product promise:

> Mia silently learns everything and changes your budget on her own.

## Product model

The participant is still the **Household CFO**.

Mia is:

- a coach,
- a translator of financial facts,
- a memory-aware assistant,
- a proposer of changes,
- never the authority that silently mutates financial truth.

Rails/Postgres still own:

- calculations,
- validations,
- budget writes,
- actuals,
- document application,
- draft confirmation,
- matching/reconciliation,
- audit logs.

The safe agentic model is:

```text
User asks Mia to remember, update, or adjust something
-> Claude resolves conversational intent/references into a strict supported schema
-> Rails validates every referenced record, amount, month, and allowed action
-> Mia/Rails produces a structured draft or suggestion
-> UI shows a reviewable diff/card
-> Household CFO confirms, edits, or cancels
-> Rails revalidates and applies
-> Audit log records who proposed, who approved, and what changed
```

Rails supplies truth and safe tools; it does not script Mia's wording. Claude handles language, references, corrections, and conversational continuity. Claude never receives a general-purpose write primitive and cannot bypass the review card.

## Design principle: supervised agent, not autonomous editor

Mia can propose changes like:

```text
Lower dining out to $250 for the rest of the year and move the extra $50/month to emergency fund.
```

But the UI should show a review card before anything changes:

```text
Proposed budget changes

Dining Out
Aug-Dec: $300 -> $250

Emergency Fund
Aug-Dec: $100 -> $150

Net monthly change
$0

[Apply changes] [Edit] [Cancel]
```

Mia's language should be:

- "I can prepare that change for your review."
- "Here is what would change if you approve it."
- "You stay the CFO here — confirm before I update the plan."

Avoid:

- "I updated your budget."
- "I moved the money for you."
- "I recorded that as actuals."

Unless Rails has already applied a confirmed write.

## Relationship between memory and actions

Memory and action drafts are related, but they are not the same feature.

### Memory

Memory answers:

> What should Mia remember about this household or participant for future coaching?

Examples:

- preferred check-in day,
- top household goal,
- stressful categories,
- communication style,
- known upcoming irregular expense,
- user preference for direct vs gentle coaching.

### Action drafts

Action drafts answer:

> What concrete change does the Household CFO want to review and apply?

Examples:

- update planned budget allocations,
- create or rename a category,
- move money between categories,
- apply income forward,
- reclassify a pending transaction draft,
- accept a memory suggestion.

Recommended order:

1. Build **Mia Action Drafts** for budget/category edits first because they directly improve the budget loop and stay safely review-before-apply.
2. Discuss **Mia Memory** with Mrs. Mel before implementation so trust, visibility, sensitivity, and coach access are clear.
3. Then build the **Mia Memory MVP** with visible/user-controlled controls.
4. Then polish the annual budget UX around those actions.

Action drafts make Mia useful as an assistant that can help operate the plan. Memory gives Mia continuity, but it should be scoped with Mrs. Mel first.

---

# PR #32 — Mia Action Drafts / supervised budget editing (merged)

This is the first implementation track after PR #31. It also establishes the structured intent/context layer required for action drafts to behave like a coherent assistant instead of a regex command parser.

Conversation context uses:

- up to 32 recent role-preserving messages within a 24,000-character budget,
- versioned active-thread state with the resolved action and review lifecycle,
- pending transaction/action review ids,
- selected month/year and an allowed category catalog,
- an older compacted summary only after recent raw turns,
- model-backed strict JSON intent resolution with Rails allowlist validation,
- deterministic explicit-command fallback and clarification instead of guessing when the model is unavailable.

The narrow v1 write scope is budget/category edits only:

- planned allocation edits,
- planned-dollar moves between categories,
- category create/rename/reclassify,
- category archive/restore when Rails validations allow it,
- review card with apply/cancel,
- audit events,
- no actuals/document/profile/debt/asset writes.

---

# PR #33 — Mia Memory MVP, after Mrs. Mel discovery

## Goal

Mia should remember stable household facts, coaching preferences, and follow-up commitments in a way users can see and control.

This is inspired by Hermes/OpenClaw, but simplified for non-technical users.

Hermes/OpenClaw ideas worth borrowing:

- persistent context,
- session summaries,
- user preferences,
- reusable playbooks,
- learning from corrections,
- follow-up loops.

What Household CFO should avoid:

- technical setup,
- prompt management,
- hidden memory files,
- raw chat treated as truth,
- vector database complexity as the first implementation,
- autonomous self-modification,
- memory that users cannot inspect or delete.

## User-facing promise

> Mia remembers what helps your household stay on track — and you can edit or forget anything.

## Data model direction

Use structured Postgres memory first. No vector database required for the MVP.

Possible table:

```text
household_memories
```

Suggested fields:

```text
id
household_id
user_id                    # optional owner/source participant
category                   # goal, preference, constraint, habit, coaching_style, follow_up, coach_note
status                     # inferred, pending_confirmation, user_confirmed, coach_confirmed, rejected, expired
visibility                 # participant_visible, coach_visible, private_to_user
sensitivity                # low, medium, high
title                      # short display label
content                    # human-readable memory
structured_value           # jsonb for machine-readable details
source_type                # chat_message, onboarding, user_manual, coach_admin_note, system_observation
source_id
confidence                 # optional decimal
last_used_at
expires_on
created_by_type            # user, mia, coach, system
created_by_id
updated_by_type
updated_by_id
discarded_at / archived_at
created_at
updated_at
```

Keep memory small and curated. Do not store entire transcripts as memory.

## Memory categories

Start with these:

- `goal` — "build emergency fund to $5,000"
- `preference` — "prefers Friday check-ins"
- `constraint` — "rent is due on the 1st"
- `habit` — "dining out is the pattern to watch"
- `coaching_style` — "prefers direct accountability"
- `follow_up` — "review grocery spending next payday"
- `coach_note` — future coach/admin note, visibility-controlled

## Sensitivity and confirmation rules

Low-risk memories can be saved with lightweight confirmation:

- check-in cadence,
- tone preference,
- preferred category names,
- UI preferences.

Sensitive memories should require explicit confirmation:

- debt stress,
- income instability,
- family constraints,
- health/medical constraints,
- relationship details,
- job transition concerns,
- anything coach-visible.

Mia should ask:

```text
Do you want me to remember that your top goal right now is paying off this card before building the emergency fund?
```

User options:

```text
[Remember] [Not this] [Edit first]
```

## User controls

Add a simple UI section:

```text
What Mia remembers
```

Controls:

- edit,
- forget,
- do not remember this,
- remember this for next time,
- pause personalization,
- resume personalization.

This can initially live in My Profile or Ask Mia settings. Long term it can become a dedicated memory panel.

## Personalization pause

A household or user should be able to pause personalization.

When paused:

- Mia still answers from approved financial records.
- Mia does not create new memory suggestions.
- Existing memories are not injected into Mia context unless explicitly allowed by the user.
- Financial truth and audit logs still work normally.

## Context injection rules

Mia context should include only relevant, approved memories.

Priority order stays:

1. Safety and financial boundaries.
2. Mia persona / response contract.
3. Structured household financial records.
4. Active annual plan, transactions, pending drafts, document status.
5. Relevant confirmed memories.
6. Recent chat/compacted conversation.
7. General model knowledge only when app data does not answer.

Memory never overrides structured money truth.

Example:

- Memory says user usually gets paid Friday.
- Payroll/profile record says current income cadence is biweekly Wednesday.
- Mia must treat the structured profile as the factual source and can mention the memory only as stale/possibly needing update.

## Memory creation in MVP

Start simple.

Phase 1 memory sources:

1. Manual user action: "Remember this."
2. Mia suggestion after a chat: "Want me to remember this?"
3. Profile/onboarding fields converted into visible memory records.
4. Deterministic follow-up memories from user-confirmed actions.

Do not start with broad background chat mining.

## API surface direction

Possible endpoints:

```text
GET    /api/v1/mia/memories
POST   /api/v1/mia/memories
PATCH  /api/v1/mia/memories/:id
DELETE /api/v1/mia/memories/:id
POST   /api/v1/mia/memories/:id/confirm
POST   /api/v1/mia/memories/:id/reject
PATCH  /api/v1/workspace/personalization
```

Names can change, but the product needs explicit user control.

## Tests / evals

PR #33 should add tests for:

- household scoping,
- user can list/edit/delete only their household memories,
- pause personalization blocks new memory suggestions,
- sensitive memory requires confirmation,
- raw chat is not treated as memory automatically,
- Mia context includes confirmed relevant memories,
- memories do not override structured financial facts,
- clearing chat does not delete curated memory,
- deleting memory removes it from future Mia context.

Add eval cases like:

- "Remember that Friday check-ins work best for me."
- "Don't remember that."
- "What do you remember about me?"
- "Forget my dining-out preference."
- "Actually rent is due on the 1st, not the 15th."

## PR #33 acceptance criteria

- User can view what Mia remembers.
- User can edit and forget memories.
- User can pause personalization.
- Mia can suggest saving a low-risk memory.
- Sensitive memories require explicit confirmation.
- Confirmed memories can influence Mia's coaching tone/context.
- Memory cannot change budget, profile, transactions, or actuals by itself.
- Tests prove memory is household-scoped and user-controlled.

---

# PR #32 implementation details — Mia Action Drafts / supervised budget editing

## Goal

Mia can help operate the household plan by preparing reviewable changes, while Rails validates and applies only after user approval.

This is where Mia starts feeling more like a proper assistant/agent instead of a chatbot.

## First supported actions

Start with budget and category actions, not actuals.

Good v1 actions:

- update planned budget allocation for one month,
- update planned budget allocation across future months,
- move planned dollars between categories,
- create a category,
- rename a category,
- reclassify a category's Expense Stack key,

Defer or keep stricter:

- confirming actuals,
- applying document extraction values,
- deleting source files,
- archiving categories with history,
- changing debts/assets/profile facts,
- memory suggestions,
- coach-visible notes,
- anything tax/legal/investment-related.

## Data model direction

Possible tables:

```text
mia_action_drafts
mia_action_items
household_audit_events
```

### `mia_action_drafts`

```text
id
household_id
user_id
chat_message_id
status                 # pending, applied, canceled, expired, failed
intent                 # update_budget, create_category, move_money, update_memory, etc.
summary
risk_level             # low, medium, high
created_by             # mia, user, system
approved_by_user_id
applied_at
canceled_at
error_message
created_at
updated_at
```

### `mia_action_items`

```text
id
mia_action_draft_id
action_type            # update_budget_allocation, create_category, rename_category, etc.
target_type
target_id
period_id              # for monthly budget changes
before_value           # jsonb
after_value            # jsonb
validation_status
validation_error
position
created_at
updated_at
```

### `household_audit_events`

```text
id
household_id
actor_type             # user, mia, system, coach
actor_id
event_type             # proposed, approved, applied, canceled, edited
entity_type
entity_id
source_type            # mia_action_draft, transaction_draft, document_import, manual_edit
source_id
before_value           # jsonb
after_value            # jsonb
metadata               # jsonb
created_at
```

Audit wording should be clear:

```text
Mia suggested this change.
Leon approved this change.
Rails applied this change.
```

Not:

```text
Mia changed your budget.
```

## Review UI

Every action draft should render as a diff card.

Example:

```text
Mia prepared 2 changes for review

Dining Out
Aug-Dec: $300 -> $250

Emergency Fund
Aug-Dec: $100 -> $150

Monthly plan total
No change

[Apply changes] [Edit] [Cancel]
```

If a change affects multiple months, show the month range and allow expansion.

## Validation rules

Before showing a draft:

- check household ownership,
- check target records exist,
- check categories are active unless explicitly restoring,
- check amount values are valid cents,
- check period/year is supported,
- check net movement if user requested no total change,
- check conflicts with pending drafts or archived categories.

Before applying:

- revalidate everything inside a database transaction,
- lock affected budget rows if needed,
- apply changes,
- write audit events,
- return refreshed budget data.

## Agent boundary

Mia can parse and propose. Rails decides if a proposed action is valid.

The model should never be trusted to directly write:

- SQL,
- arbitrary attribute names,
- unbounded JSON patches,
- actuals,
- source documents,
- user roles,
- admin/cohort access.

Use explicit action schemas only.

## Tests / evals

Add tests for:

- budget change proposal creates draft, not write,
- apply changes only after explicit confirmation,
- canceled drafts do not mutate budget,
- invalid target/category/month fails safely,
- audit event records before/after values,
- Mia cannot claim the change was applied before confirmation,
- multiple-month propagation is correct,
- action draft belongs to same household,
- no actuals change through action drafts.

Eval prompts:

- "Lower dining out to $250 for the rest of the year."
- "Move $50 from eating out to emergency fund each month."
- "Create a cigarettes category under discretionary."
- "Rename Eating Out to Dining Out."
- "Did you already change my budget?"

Expected response before confirm:

```text
I prepared that as a change for your review. Your budget will not update until you approve it.
```

## PR #33 acceptance criteria

- Mia can prepare at least one budget allocation change draft.
- UI shows a diff before applying.
- User can apply/cancel.
- Rails validates and applies only on confirmation.
- Audit log records suggested/approved/applied state.
- No actuals or document values can be changed through this path.

---

# UX/product polish track

After memory and action drafts, improve the product surface so these capabilities are easy for non-technical users.

Priorities:

- annual budget table/list view,
- year view with current month collapsed/expanded,
- fixed/discretionary/sinking fund education in the UI,
- warm neutral palette pass,
- Ask Mia review cards for memory/action drafts,
- clearer budget category management,
- mobile-first review/apply flows.

This should not change the core safety model.

## Open questions before implementation

- Should memories be household-level, user-level, or both?
- Which memories can a future coach/admin see by default?
- Should coach-visible memory require participant opt-in?
- Which action drafts should ship first: budget allocation edits or memory suggestions?
- Should action drafts reuse the transaction draft review-card style or get a separate component family?
- How long should pending memories/action drafts stay active before expiring?
- What is the minimum audit log UI needed for pilot confidence?

## Working decision

Build Mia toward a simple, trustworthy assistant:

```text
Mia remembers with permission.
Mia proposes with structure.
The Household CFO approves.
Rails validates and applies.
The audit log records what happened.
```
