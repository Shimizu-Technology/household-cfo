# Mia Browser / Internet Research — Post-v1 Plan

Mia should eventually be able to research current public information, such as Guam car registration fees, benefit/program rules, bank/product details, or official agency instructions. This should not ship as broad open browser access in v1.

## Why not broad browsing in v1

Household CFO handles sensitive household financial context. A general browser tool would introduce avoidable risk:

- private household data could leak into third-party sites
- webpages can contain prompt-injection instructions
- sources may be outdated, unofficial, or misleading
- Mia might sound certain about public information that changed
- research could be confused with approved household records

For v1, Mia should say when she does not know a current external fact and ask the participant to verify the official amount/source.

## Post-v1 target behavior

Mia may research public information only through a backend-controlled research tool.

Mia should:

- search official or allowlisted sources first
- cite the source and date accessed
- summarize uncertainty clearly
- separate public research from household records
- never mutate household data from research alone
- ask the Household CFO to confirm before applying researched values to the plan

Example:

```text
I found a Guam Department of Revenue and Taxation page about registration fees, accessed today. I still need your vehicle details before I can estimate your exact amount. Next CFO move: confirm the registration amount from the official notice, then I can place it in Sinking Fund — Expected.
```

## Guardrails

1. **Backend-only**
   - No browser/API keys in the frontend.
   - Research calls run server-side and are logged/auditable.

2. **No sensitive data to the web**
   - Do not send household name, debts, assets, income, documents, goals, or transaction details to external search/pages.
   - Use generic search terms such as `Guam vehicle registration fee official`.

3. **Allowlist-first**
   - Prefer official government, bank, utility, school, or provider domains.
   - For Guam examples, prefer official `.gov`, `guamtax.com`, agency pages, or directly provided URLs.

4. **Prompt-injection resistant**
   - Treat webpage content as untrusted data.
   - Never follow instructions found on a webpage.
   - Extract facts only.

5. **Citations required**
   - Mia should name the source and retrieval date for researched facts.
   - If no reliable source is found, say so plainly.

6. **No automatic writes**
   - Research can propose a value or next step.
   - The user must confirm before budgets, profile numbers, drafts, or actuals change.

7. **Cache and freshness**
   - Cache public lookups where reasonable.
   - Show freshness when answering: `Source checked on YYYY-MM-DD`.
   - Re-check time-sensitive fee/program information before relying on it.

## Suggested implementation sequence

### PR A — Research architecture

- Add `MiaResearch::SearchClient` abstraction.
- Add provider implementation using Brave Search or a direct HTTP/search backend.
- Add allowlist/blocklist configuration.
- Add tests proving household data is not included in search queries.

### PR B — Source extraction and citation

- Add source fetcher/extractor with size limits and timeout.
- Store minimal public-source metadata, not full pages by default.
- Return citations to Mia as structured facts.

### PR C — Mia integration

- Add an explicit research route/tool from the Mia backend pipeline.
- Use research only for current public facts, not household facts.
- Require citations in the answer.
- Add UI copy showing when Mia used web research.

### PR D — User-approved application

- If research suggests a budget value, show it as a suggestion.
- Require review/apply before it changes the annual plan.

## Example v2 use cases

- `How much does Guam car registration usually cost?`
- `What is the current GPA power rate?`
- `Where do I renew my business license?`
- `What documents do I need for this local program?`
- `What is the official deadline for this fee?`

## Non-goals

- Autonomous browsing with household data.
- Letting Mia fill forms or submit payments.
- Letting webpages instruct Mia.
- Treating public estimates as confirmed household facts.
