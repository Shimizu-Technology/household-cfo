# Pilot analytics and cohort privacy contract

The pilot uses a deliberately small operational funnel. Product analytics may show that a workflow occurred, but must never contain the participant's financial or personal content.

## Core funnel events

| Pilot signal | Event | Safe meaning |
| --- | --- | --- |
| Setup/profile saved | `workspace_setup_saved` | A participant saved setup; boolean completion state only. |
| First Mia conversation | First `mia_message_sent` | A participant sent a message; no message text or attachment content. |
| First upload | First `document_import_upload_succeeded` | An allowed document type uploaded successfully; generic document kind only. |
| First draft created | First transaction or Mia action draft-presented event | A supervised draft became reviewable; no amount, merchant, category, or message text. |
| First confirmation | First `transaction_draft_confirmed` | A participant explicitly confirmed a transaction draft. |
| Workflow failure | `pilot_workflow_failed` | A named workflow and generic failure stage failed. |
| Review completion | `pilot_review_completed` | A named review ended with a generic outcome such as applied, confirmed, ignored, or cancelled. |

The first occurrence is derived in PostHog; the application does not need a second event containing participant details.

## Allowed properties

Event properties are limited to operational enums and booleans such as:

- workflow or review type;
- generic outcome or failure stage;
- generic document kind;
- whether a screenshot or attachment was present;
- application role/status;
- safe route path without query string or fragment.

Never send names, email addresses, household names, financial values, amount buckets, balances, account or card numbers, merchant names, category names, document text, filenames, source URLs, Mia message/transcript text, feedback narrative, or screenshot content to PostHog.

Autocapture is disabled. Replay masks all text and inputs. Page views use only origin plus pathname; query strings and fragments are excluded. Network replay also redacts query strings and private source URLs.

## Feedback boundary

Pilot feedback is submitted to the authenticated Rails API and scoped to the participant's household. The structured narrative and optional screenshot are not copied to analytics. Analytics receives only a generic success or failure signal with the selected workflow and screenshot-present boolean.

Feedback content is for technical support, not the cohort progress view. It may contain accidental private context despite the in-product warning, so Mrs. Mel's cohort screen must not expose it.

## Cohort visibility boundary

Mrs. Mel may see only operational progress needed to support the cohort:

- invited;
- signed in;
- setup not started, started, or completed;
- whether pending review work exists;
- last safe activity timestamp.

The cohort/admin API must not return participant financial values, documents, private messages, transaction details, setup percentages, or readiness/financial-health scores. Access to participant financial details requires a separate future product decision and authorization design.
