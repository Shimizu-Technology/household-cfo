# Plaid Sandbox failure matrix

Run this before production submission changes, after Plaid SDK/sync changes, and before the first real-data pilot. Record date, commit, tester, Sandbox Item, expected result, actual result, and sanitized evidence location. Never commit credentials, Plaid IDs, balances, transaction details, or real customer data.

## Automated gate

```bash
cd api
bundle exec rails test \
  test/services/plaid_integration_configuration_test.rb \
  test/services/plaid_integration_item_health_test.rb \
  test/services/plaid_integration_item_disconnector_test.rb \
  test/services/plaid_integration_item_webhook_handler_test.rb \
  test/services/plaid_integration_link_token_test.rb \
  test/services/plaid_integration_transaction_sync_test.rb \
  test/services/plaid_integration_webhook_verifier_test.rb \
  test/jobs/plaid_stale_item_recovery_job_test.rb \
  test/controllers/api_plaid_webhooks_controller_test.rb \
  test/controllers/api_v1_admin_plaid_health_controller_test.rb \
  test/controllers/api_v1_plaid_controller_test.rb
```

## Signed-in Sandbox scenarios

| Scenario | Expected result |
| --- | --- |
| Initial Link | Consent required; Link opens with Transactions only; OAuth return can resume; first history sync becomes current. |
| Pending to posted | Pending row stays informational; posted replacement creates one review draft; no duplicate actual or draft. |
| Modified transaction | Source row updates; an already reviewed source is visibly marked changed and does not silently rewrite an actual. |
| Removed transaction | Source is marked removed; any prior confirmed actual remains visible for reconciliation. |
| Duplicate/out-of-order transaction webhooks | Jobs may enqueue, but cursor sync remains idempotent and produces no duplicate rows/drafts. |
| Missed webhook | Backdate a Sandbox Item's successful-update timestamp, run the recovery job, and verify one Item-scoped sync is queued. |
| Login required | Item becomes reconnect-needed without storing Plaid's raw error message; update-mode Link can repair it. |
| Login repaired | Item returns active and queues sync. |
| Account permission revoked | Affected source rows and their pending drafts are removed; confirmed household actuals and unrelated drafts remain. |
| New account available | Item becomes reconnect-needed so the household explicitly authorizes the added account. |
| Manual sync | Request returns immediately, background sync runs, freshness advances, and connection health returns current. |
| Temporary disconnect failure | Token and source data remain; status allows a safe retry. |
| Successful disconnect/retry after Item removal | Plaid removal completes or an already-removed retry is recognized; token, source accounts/transactions, and pending source drafts are removed; confirmed actuals remain. |
| Household isolation | A user cannot list, sync, stage, ignore, reconnect, or disconnect another household's Item or transactions. |
| Admin health | Admin sees status/freshness metadata only; participants are forbidden; response contains no Plaid IDs, tokens, balances, or transactions. |
| Mia bank question | Mia answers from authorized bank activity, clearly separates bank-observed, pending review, and confirmed actuals, and makes no write claim. |
| Auto-confirm boundary | Default remains off. When explicitly enabled, only a proven exact merchant-category rule within amount tolerance can confirm; duplicates/unusual amounts wait. |

## Completion record

```text
Date:
Commit:
Tester:
Browser/device:
Sandbox institution/user:
Automated gate:
Signed-in scenarios passed:
Failures and disposition:
Sanitized evidence location:
```
