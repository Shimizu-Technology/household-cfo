# Post-PR #31 roadmap: supervised actions, memory discovery, and pilot polish

Updated: 2026-07-09

PR #29 delivered the Document Intelligence Platform v1. PR #30 added the Mia Coaching Quality / Model Narrator layer. PR #31 added voice input through backend-only OpenRouter STT and a YAML-backed real-world eval harness.

The app now has the real Household CFO MVP foundation Mrs. Mel asked for: annual budgets, confirmed actuals, pending transaction drafts, receipt/statement/document extraction, review-before-apply flows, persisted Mia chat, safer model narration, and editable voice transcripts.

## Current product state

### Done

- User is framed as the Household CFO; Mia is the coach/assistant.
- Clerk/Postgres real workspaces, admin/cohort management, invite flow, persisted Mia chat.
- Annual budget model: budget years, months, categories, allocations, actuals, pending drafts.
- Text transaction loop: Mia can draft spend entries; user confirms/edits/ignores before actuals change.
- Document Intelligence Platform v1 with private S3, extraction history, reviewable budget/profile facts, transaction drafts, split drafts, statement rows, matching, lineage, reopen/undo, and import history.
- Mia chat attachments can process receipt screenshots into reviewable drafts.
- Mia narration uses Rails-approved answer packets and falls back safely.
- Voice input uploads browser audio to Rails, transcribes through backend-only OpenRouter STT, inserts editable transcript into the composer, and never auto-sends or auto-confirms.
- YAML eval harness covers real-world prompts for spending reports, manual spend drafts, pending-vs-actual guardrails, budgeting, and coaching boundaries.
- Rails remains the source of truth. Pending drafts never count as actuals.

### Immediate validation still needed

- Production smoke on `https://householdcfomethod.com` with the real smoke account.
- Confirm production envs: Clerk, Render CORS, S3, OpenRouter, Resend, PostHog.
- Phone receipt screenshot upload -> Mia reply -> review card -> confirm -> budget actuals update.
- Statement screenshot/file upload -> rows land in correct months -> match/dedupe works.
- Ask Mia voice input -> editable transcript -> pending draft only -> confirm/ignore.
- Desktop/mobile Mia convergence and private source preview/download work.

## Next build priority

Mrs. Mel's strongest remaining product feedback is that the transaction loop and conversation loop are the core. Now that Rails owns the money truth, the next phase is making Mia feel like a supervised Household CFO Method assistant instead of a service-generated calculator.

Recommended order:

1. **Production/staging smoke test after PR #31 merge**
2. **PR #32 — Mia Action Drafts / supervised budget editing**
3. **Mrs. Mel discovery conversation for Mia Memory**
4. **PR #33 — Mia Memory MVP, after scope/trust/visibility are confirmed**
5. **PR #34 — UX/product polish + annual budget table improvements**
6. **Later — FinCon coach-skin / white-label foundation**

The detailed memory/action plan lives in:

```text
docs/mia-memory-and-supervised-actions.md
```

## PR #32 — Mia Action Drafts / supervised budget editing

Goal: Mia can help operate the household plan by preparing reviewable changes, while Rails validates and applies only after user approval.

Product rule:

```text
Mia proposes.
The Household CFO approves.
Rails validates and applies.
The audit log records what happened.
```

Initial scope:

- Add `mia_action_drafts` and `mia_action_items` for reviewable proposed changes.
- Add `household_audit_events` for proposed/applied/canceled records.
- Support first budget/category actions:
  - update planned budget allocation for one month or the annual plan,
  - move planned dollars between categories,
  - create a category,
  - rename a category,
  - reclassify a category's Expense Stack key,
  - archive/restore a category when Rails validations allow it.
- Render review cards with before/after values and clear apply/cancel controls.
- Apply only after explicit user confirmation.
- Revalidate inside Rails transaction before applying.

Non-goals for first action-draft PR:

- Do not confirm actuals through this path.
- Do not apply document extraction values through this path.
- Do not delete source files.
- Do not change debts/assets/profile facts without a separate specialized review flow.
- Do not allow arbitrary model-generated JSON patches or SQL-like operations.

Acceptance criteria:

- User can ask Mia to prepare a budget change.
- UI shows the proposed diff before applying.
- Canceling does not mutate anything.
- Applying writes through Rails validations only.
- Audit log records who proposed, who approved/canceled, and what changed.
- Mia does not claim a change was applied before confirmation.

## PR #33 — Mia Memory MVP, after Mrs. Mel discovery

Goal: Mia feels continuous and personal without treating raw chat as financial truth.

Memory should be discussed with Mrs. Mel before implementation so the product lands as helpful, visible personalization instead of hidden surveillance.

Discovery questions:

- What should Mia remember automatically, if anything?
- Which memories require explicit permission?
- What can a future coach/admin see?
- How should users edit, forget, or pause memory?
- Which sensitive facts should never be remembered unless the user asks?

Likely scope:

- Add structured `household_memories` / `mia_memories` table.
- Memory categories: goal, preference, constraint, habit, coaching_style, follow_up, coach_note.
- Statuses: inferred, pending_confirmation, user_confirmed, coach_confirmed, rejected, expired.
- Sensitivity/visibility fields so sensitive memories require confirmation and future coach-visible notes can be controlled.
- User-facing UI: `What Mia remembers`.
- Controls: edit, forget, do not remember this, remember this for next time, pause personalization.
- Include confirmed, relevant memories in Mia context.
- Keep raw chat separate from curated memory.

Acceptance criteria:

- User can inspect, edit, and remove memories.
- User can pause personalization.
- Mia can remember low-risk preferences like Friday check-ins.
- Mia asks before saving sensitive goals/constraints.
- Confirmed memories can influence Mia's coaching tone/context.
- Memory never changes budget, actuals, profile facts, document facts, or transactions by itself.
- Tests prove memory is household-scoped and user-controlled.

## PR #34 — UX/product polish + annual budget table improvements

Goal: make the new supervised-action and future-memory capabilities understandable for non-technical pilot users.

Scope:

- Annual budget table/list view with expandable year/month structure.
- Clear fixed/discretionary/sinking fund education in the Budget UI.
- Warm neutral palette pass away from heavy green.
- Ask Mia review cards for transaction drafts, memory suggestions, and action drafts.
- Better category setup/editing flow.
- Mobile-first review/apply polish.

## Later / FinCon coach-skin foundation

- Coach/program skin model: logo, colors, theme, assistant persona, content repository.
- Optional modules: retirement calculator, biblical finance, youth finance, etc.
- Coach/admin intelligence dashboard.
- Pricing/subscription foundation.
- Founding coach testing flow with Mrs. Mel/Bethany.

## Production rule

Do not add new financial write paths that bypass review. Mia can propose; Rails validates; the Household CFO confirms.
