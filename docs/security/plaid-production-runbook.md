# Plaid production runbook

Owner: Shimizu Technology LLC · Product: Household CFO Method · Scope: read-only Transactions

This is the production approval, launch, monitoring, and recovery record. Never place Plaid secrets, access tokens, real account identifiers, balances, transactions, or customer evidence in this file or git.

## Approval packet

- Legal entity/account owner: Shimizu Technology LLC.
- Product purpose: help a household track and manage its finances by viewing authorized balances and transaction activity, asking Mia questions about that activity, and approving posted outflows into categorized budget actuals.
- Plaid product: Transactions only.
- Data Transparency Messaging use case: **Track and manage your finances**.
- Payment initiation, money movement, Auth, Identity, Transfer, Signal, and Payments: not requested.
- Data notice: `/privacy.html`; technical flow: `docs/security/plaid-data-flow.md`.
- User control: explicit consent before Link, reconnect/update mode, manual sync, disconnect, and auto-confirm off by default.

## Dashboard configuration

Record completion date and reviewer initials outside git if the evidence includes private dashboard details.

- [ ] Production access application is complete and submitted.
- [ ] Link customization is published with the approved use case and its exact name is stored as `PLAID_LINK_CUSTOMIZATION_NAME`.
- [ ] Production webhook is the public API origin plus `/api/plaid/webhook`.
- [ ] Production OAuth redirect exactly matches the canonical HTTPS application URL registered in Plaid.
- [ ] Every Plaid Dashboard team member shows 2FA **ON** under Team Members.
- [ ] Only necessary Shimizu Technology team members retain Dashboard access.

Plaid Dashboard 2FA is independent from Clerk participant authentication. A Clerk plan upgrade is not required for Plaid API integration or Plaid Dashboard 2FA.

## Runtime configuration

Set backend-only values in the API host. Never expose them through `VITE_*` variables.

```text
PLAID_ENV=production
PLAID_CLIENT_ID=...
PLAID_SECRET=...
PLAID_DATA_ENCRYPTION_KEY=...
PLAID_WEBHOOK_URL=https://<api-origin>/api/plaid/webhook
PLAID_REDIRECT_URI=https://<canonical-app-origin>/
PLAID_LINK_CUSTOMIZATION_NAME=<published-customization-name>
SOLID_QUEUE_IN_PUMA=true
```

Production-mode startup validates credentials, HTTPS webhook path, and HTTPS redirect. Keep exactly one Solid Queue owner. The recurring recovery job runs daily at 17:17 server time and queues active Items whose last successful update is more than 24 hours old; the user-facing stale threshold is 36 hours.

## Secret and encryption-key recovery

Plaid secret rotation:

1. Generate the next secret in Plaid Dashboard while the current secret remains active.
2. Update the API host secret and deploy.
3. Complete Link-token creation, Sandbox/Development smoke checks, and webhook verification.
4. Retire the previous secret only after the new deployment is verified.

Data-encryption key:

- Store the 32-byte key in the approved secret manager and an access-controlled recovery location separate from the database backup.
- Never rotate it by simply replacing the environment value: existing Item tokens would become undecryptable.
- A planned rotation requires dual-key decryption, re-encryption of every stored token, verification, and only then retirement of the old key.
- If the key is irretrievably lost, existing connections cannot be recovered. Disconnect/remove affected Items in coordination with Plaid when possible, clear local source data safely, and ask each household to reconnect.

Database backups must be encrypted, access controlled, restore-tested, and retained according to Shimizu Technology policy. A restore test must verify household isolation, confirmed-actual preservation, encrypted-token decryptability, and queue consistency without using production financial values in screenshots or tickets.

## Monitoring and response

- The participant connection card shows current, initializing, delayed, reconnect-needed, error, and disconnect-pending states.
- The Admin bank-feed ledger shows metadata-only counts and rows. It deliberately excludes balances, transactions, Plaid IDs, and tokens.
- Handled sync failures are reported through `Rails.error` with only the internal Item record ID and safe Plaid error code.
- Webhooks remain the primary update trigger. The daily recovery job covers missed or delayed notifications.

Response order:

1. Check Admin bank-feed health and the application error monitor.
2. For `update_required`, have the household use Reconnect; never request bank credentials through support.
3. For `error` or `stale`, try one manual sync, then inspect Plaid Dashboard request/webhook logs using its request reference.
4. For `disconnecting`, retry Disconnect so `/item/remove` can finish before local credentials are erased.
5. Escalate persistent institution-specific failures to Plaid with request IDs only; do not send access tokens or unnecessary financial data.

## Post-approval pilot

1. Use Leon's own account first; do not use Mrs. Mel or another participant as the first real-data test.
2. Keep trusted-merchant auto-confirm off.
3. Connect one institution, verify OAuth return, account list, masks, and balances against the official portal.
4. Verify pending to posted replacement, modifications/removals, manual sync, webhook freshness, review draft creation, confirmation boundary, Mia lookup, reconnect, and disconnect.
5. Treat Bank of Guam and Coast360 production behavior as unproven until each is tested with consent. Sandbox institution behavior does not guarantee production data coverage or update timing.
6. Expand beyond Leon only after the privacy notice, health ledger, alerts, disconnect flow, and data comparisons are all verified.
