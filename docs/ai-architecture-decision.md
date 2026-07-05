# AI architecture decision: Rails first, Python only when it earns its keep

Updated: 2026-07-04

## Decision

Household CFO should keep this v1 architecture:

```text
web/ React + Vite + TypeScript
api/ Rails API + PostgreSQL
AI calls server-side from Rails
```

Do **not** add a Python/FastAPI service for PR #20 or the immediate cohort MVP unless a specific AI/document workload proves Rails is the wrong tool.

## Why

The product's highest-risk work right now is not advanced AI infrastructure. It is:

- trustworthy annual budget math
- transaction draft → user review → confirmed actuals
- private document handling
- Mia response safety and continuity
- admin/cohort operations
- production smoke testing

Rails/Postgres is the right source of truth for those workflows because it keeps auth, household ownership, auditability, validations, jobs, and financial writes in one backend.

## What must stay deterministic in Rails

Rails should continue to own:

- balances, budgets, actuals, reports, and remaining amounts
- planned vs confirmed vs pending separation
- transaction creation/confirmation/ignore rules
- category archive/restore rules
- document import review/apply behavior
- safety/product boundaries that cannot be overridden by prompts
- all writes to Postgres

Mia can explain, coach, and propose, but Rails validates and writes.

## Where the model should help

The model is most useful for:

- natural coaching tone
- summarizing a user's situation
- extracting draft facts from receipts/statements/pay stubs
- proposing categories/splits for review
- turning deterministic facts into a human plan
- later, searching curated coach/program content

Model output should still become a draft/proposal until the participant confirms.

## When to add Python/FastAPI

Add a separate Python worker/service only if one of these becomes true:

1. Receipt/statement/pay-stub parsing needs Python-first libraries for layout, tables, OCR post-processing, or dataframes.
2. We need embeddings/RAG pipelines, batch evals, or model-quality experiments that are awkward in Rails.
3. AI/document jobs need to scale independently from the Rails app.
4. A clear library advantage exists, e.g. `pandas`, `layoutparser`, specialized PDF/table tooling, or a model-eval framework.
5. Rails jobs become hard to operate because AI workloads are long-running, memory-heavy, or high-concurrency.

## How to add it later without rewriting the app

If Python becomes necessary, keep Rails as the system of record:

```text
React uploads/chat -> Rails API -> private S3/Postgres -> background job
Rails job calls Python worker/service with signed internal reference
Python returns structured draft JSON only
Rails validates, stores draft facts, and exposes review UI
User confirms -> Rails writes official records
```

Rules for the Python service:

- no direct browser access
- no public file URLs
- no direct writes to financial truth tables
- no raw private document content in logs
- return bounded structured JSON with confidence/warnings
- Rails remains responsible for authorization, validation, audit, and apply

## Sources / project context

This matches the earlier project notes:

- `Brain-Dump/work/shimizu-tech/Mel-Mendiola-ASC-Trust/18) Household CFO shared drive review - 2026-06-18.md`
- `Brain-Dump/work/shimizu-tech/Mel-Mendiola-ASC-Trust/20) Agreement sent and current status - 2026-06-18.md`
- `docs/real-mode-build-plan.md`
- `docs/private-document-imports-and-mia-context.md`
- `docs/mia-response-contract.md`
- `docs/mrs-mel-v1-feedback-implementation-plan.md`
