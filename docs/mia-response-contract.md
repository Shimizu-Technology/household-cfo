# Mia Response Contract v1

Mia should feel like a real Household CFO coach, not a generic finance chatbot and not a calculator dumping totals. This contract defines how Mia answers when the app has structured financial facts, when it has only partial context, and when Rails must protect the source of truth.

## Why this exists

Mrs. Mel's persona brief gives Mia her voice: warm, direct, culturally grounded, CBT-informed, and accountable without shame. That is necessary, but it is not enough for a finance product.

Household CFO also needs a reliable answer contract so Mia does not guess, blur planned budgets with actual spending, or imply that unapproved drafts/documents changed the user's records.

This follows the PR principle from `docs/mrs-mel-v1-feedback-implementation-plan.md`: Mia explains, coaches, and proposes; Rails validates and writes.

## Layer order

Every real Mia response should be governed in this order:

1. Non-overridable safety and product boundaries.
2. Mrs. Mel Section 7 persona seed, loaded verbatim from `api/config/mia_personas.yml`.
3. The Mia Response Contract v1.
4. Approved structured household facts from Postgres.
5. Current annual plan, selected month, confirmed transactions, pending transaction drafts, and pending Mia action drafts.
6. Approved document source/freshness summaries.
7. Confirmed relevant memories, once personalization is implemented and enabled.
8. Recent chat history.
9. General model knowledge only when app data does not answer the question.

## The contract

Mia should:

- Answer the participant's direct question first whenever the facts support a direct answer.
- Name the basis of the answer, such as confirmed transactions, active annual plan, approved household profile, or approved document summaries.
- Separate planned budget, confirmed actuals, and pending drafts.
- Never count pending drafts as actuals.
- Say clearly when a needed fact is missing, stale, pending review, or outside the available context.
- Avoid inferring financial facts from chat history when structured records are required.
- Never invent merchants, balances, categories, due dates, document findings, or transaction history.
- Ask for the smallest verification needed when unsure.
- End with one concrete Household CFO next move.

Recommended uncertainty line:

```text
Based on what I can see, I do not have enough approved data to answer that as a fact yet.
```

## How it is implemented

Persona and model-guided answers:

- `api/config/mia_personas.yml` stores `response_contract` beside the voice/persona rules.
- `api/app/services/mia/persona.rb` injects the response contract into Mia's system prompt.
- `api/app/services/demo/mia_responder.rb` also includes the critical answer-contract rules in the non-overridable safety prompt so future coach skins cannot remove them.

Model intent and narration after PR #32:

- `ConversationTranscriptBuilder` sends a token/character-bounded recent transcript of up to 32 messages instead of a fixed 12-message slice. Older context remains available through the lower-priority persisted summary.
- `MiaIntentContextBuilder` assembles the current calendar date, separately labelled budget view period, recent raw turns, active/open threads, allowed category catalog, and pending review cards without exposing raw private documents. Relative words such as today, yesterday, last month, and next month use the calendar date, not whichever month happens to be open in the UI.
- `MiaIntentResolver` lets Claude resolve intent, conversational references, corrections, and supported budget commands into a strict JSON schema before routing. Model-returned category/review ids are checked against the allowed Rails context and cannot write records directly.
- `MiaConversationStateUpdater` persists the validated active thread, resolved request, action parameters, and pending review id across reloads/devices.
- `mia_answer_packet_builder.rb` builds structured answer packets from approved household data, active annual plans, confirmed transactions, pending drafts, and conversation state.
- `mia_narrator.rb` receives the recent transcript and verified answer packet, then answers naturally in Mia's live persona. The verified reference answer is a safety/factual fallback, not a required script.
- The model may not change facts, invent missing data, imply pending drafts are actuals, or claim writes happened.
- If model intent resolution is unavailable, explicit deterministic commands still work; ambiguous confirmations ask for a precise restatement instead of guessing. If narration fails or violates guardrails, Rails returns the verified fallback.

Deterministic financial answers:

- Rails still computes money truth for reports, budget Q&A, transaction lookup, transaction drafts, and common coaching branches such as discretionary purchase checks, readiness planning, and expected sinking-fund bills like car registration.
- Deterministic services still calculate the answer packet and provide the safe fallback.
- Actuals change only when a pending `TransactionDraft` is confirmed by the Household CFO.
- Mia may edit the date, merchant, amount, category, or validated splits of an existing pending transaction review when the participant clearly asks for a correction. Rails scopes and validates the draft and every category/split; the draft remains pending and actuals remain unchanged.

Supervised action drafts:

- Mia may prepare narrow budget/category action drafts, but she must not silently mutate financial records. Profile/debt/asset action drafts require separate specialized review flows.
- The safe agentic pattern is: Mia proposes, the Household CFO reviews/approves, Rails validates/applies, and the audit log records what changed.
- Before approval, Mia should say she prepared or suggested a change, not that she updated the budget.
- Action drafts must use explicit schemas and Rails validations, never arbitrary model-generated patches or frontend-only writes.
- The detailed plan lives in `docs/mia-memory-and-supervised-actions.md`.

Conversation continuity:

- For conversational reference resolution, precedence is: current message, pending review state, recent raw transcript and explicit user corrections, version-2 validated active thread, then older/legacy summaries. A rejected assistant interpretation never outranks the participant's prior unresolved request. Current database records remain authoritative for every financial fact regardless of conversation order.
- The signed-in chat interface displays every persisted message since the participant last cleared the conversation. Display history is intentionally separate from model context: Mia still receives only up to 32 recent role-preserving messages within a 24,000-character budget, plus validated thread state and an older compact summary.
- Versioned active-thread state stores the validated intent, subject, resolved message, structured action, review id, and lifecycle status. Apply/Cancel and transaction confirmation flows update that status.
- The response narrator receives the server-validated current-turn resolution. For recall turns, it composes from that resolution instead of re-reading rejected assistant guesses from the raw transcript; structured financial records still supply the amounts and plan truth.
- The compacted older summary remains useful across long chats, but it is not the primary router and cannot override newer raw turns.
- Conversation state travels across devices for the same signed-in user because it is stored in Postgres with the chat session.
- Conversation continuity is context only, not financial truth. Confirmed actuals, balances, plans, transactions, due dates, and approved document facts still come from structured records.
- Clearing Mia chat also clears the transcript, compacted summary, and active/open thread state.

Voice input:

- Browser audio is uploaded to Rails and transcribed server-side through backend-only OpenRouter STT credentials.
- The transcript is shown in the composer for user review/editing before sending.
- Voice-created spend follows the same Mia message path as typed spend: it may create a pending draft, but never confirmed actuals.
- Failed transcription does not create records.

Document context:

- Mia receives approved structured facts and source/freshness metadata, not raw private files or S3 keys.
- Pending imports are visible as pending; extracted values do not become authoritative until reviewed/applied.

Eval harness:

- Real-world response prompts live in `api/test/evals/mia_eval_cases.yml`.
- Multi-turn intent/reference cases live in `api/test/evals/mia_intent_cases.yml`, including pronouns, confirmations, recall, pending-card reuse, and clarification.
- `HouseholdFinance::MiaEvalHarness` and intent resolver tests protect pending-vs-actual, month, draft, coaching, context, and structured-action guardrails without requiring frontend AI calls.

## What this means in practice

If the user asks:

```text
Am I staying within my budget?
```

Mia should not only recite totals. She should answer directly:

```text
Yes — based on confirmed transactions for July, you are within budget: $45 confirmed against $300 planned.
```

Then she can explain pending drafts and give the next CFO move.

If the user asks something the app cannot know yet:

```text
Can I afford my car registration next month?
```

Mia should not guess. She should say what she can see, what is missing, and what to verify next.

Post-v1 browser/internet research is documented in:

```text
docs/mia-browser-research-post-v1.md
```

## Source references

- Persona brief implementation: `docs/mia-persona-template.md`
- Mrs. Mel v1 implementation plan: `docs/mrs-mel-v1-feedback-implementation-plan.md`
- Memory/coaching vision: `/Users/leonshimizu/Desktop/ShimizuTechnology/Brain-Dump/work/shimizu-tech/Mel-Mendiola-ASC-Trust/23) Mia Memory and self-learning coaching vision - 2026-06-23.md`
- Mia Memory and supervised action plan: `docs/mia-memory-and-supervised-actions.md`
