# Plaid bank-data flow

Effective: August 16, 2026 · Owner: Shimizu Technology LLC

## Purpose and limits

Household CFO Method uses Plaid Transactions for read-only account and transaction retrieval. It does not request Auth, Transfer, Identity, or payment initiation and cannot move money.

## Flow

1. An authenticated participant explicitly accepts the bank-data notice.
2. The Rails server creates a short-lived Link token. Plaid Link handles institution credentials; they never pass through Household CFO Method.
   The token includes an allowlisted redirect URI so OAuth institutions can return mobile-web and embedded-browser users to the app. The browser keeps the short-lived Link token in user-scoped storage only for the OAuth round trip and deletes it after Link succeeds or exits.
3. Rails exchanges the one-time public token and encrypts the resulting access token with AES-256-GCM using a key stored outside the database.
4. Transaction Sync imports the minimum normalized fields needed for review and Mia's deterministic bank-activity queries. Raw Plaid payloads, locations, counterparties, and bank credentials are not retained.
5. Pending transactions and inflows remain informational. Every posted outflow is prepared automatically as a pending review draft.
6. Participant confirmation remains the default path from a draft to an actual. The separate trusted-merchant preference is off by default and can auto-confirm only after three matching approvals, within strict amount-tolerance and duplicate-candidate checks.

Mia's application logic can query all bank activity authorized for the current household. When model-backed narration is configured and the participant asks about that activity, the answer packet may contain a limited verified summary such as merchant, date, amount, review state, or aggregate totals. Plaid access credentials, bank-login credentials, raw Plaid responses, full account identifiers, and unbounded source rows are not sent to the narration provider. Analytics excludes financial values and masks session text and inputs. Logs contain internal record IDs and safe error codes, never Plaid tokens, Plaid transaction IDs, or raw API responses.

## Disconnect and retention

Disconnect calls Plaid `/item/remove` before local credentials are discarded, preventing continued billing and access. The encrypted access token, synced accounts, and Plaid transaction source rows are then removed. Participant-confirmed household transactions remain because they are user-approved financial records; unapproved source data does not.

## Operational controls

- Production requires HTTPS, server-only Plaid credentials, and a distinct 32-byte data-encryption key.
- Webhooks are accepted only after Plaid JWT and request-body hash verification.
- Transaction webhooks enqueue cursor-based synchronization. A daily recovery job also queues active Items that have not completed a successful update recently, covering missed or delayed webhooks.
- Item login, consent-expiration, new-account, permission-revocation, and self-repair webhooks update the connection state without persisting Plaid's raw error text. Account-level revocation deletes affected source rows and their unapproved drafts while retaining confirmed household actuals.
- Participants see connection health in My Profile. Administrators see a metadata-only health ledger with freshness and action-required counts; it excludes balances, transactions, Plaid identifiers, and access credentials.
- Household scoping is applied to every Item, account, transaction, staging, sync, and disconnect path.
- Access is limited to the owner/operator and authenticated household members according to application roles.
- Review this flow at least annually and after material vendor, product, or storage changes.
