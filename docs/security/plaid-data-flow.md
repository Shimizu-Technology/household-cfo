# Plaid bank-data flow

Effective: July 14, 2026 · Owner: Shimizu Technology LLC

## Purpose and limits

Household CFO Method uses Plaid Transactions for read-only account and transaction retrieval. It does not request Auth, Transfer, Identity, or payment initiation and cannot move money.

## Flow

1. An authenticated participant explicitly accepts the bank-data notice.
2. The Rails server creates a short-lived Link token. Plaid Link handles institution credentials; they never pass through Household CFO Method.
3. Rails exchanges the one-time public token and encrypts the resulting access token with AES-256-GCM using a key stored outside the database.
4. Transaction Sync imports the minimum normalized fields needed for review. Raw Plaid payloads, locations, counterparties, and bank credentials are not retained.
5. Pending transactions and inflows remain informational. A posted outflow becomes a transaction draft only after the participant selects it.
6. Existing confirmation controls remain the only path from a draft to an actual.

Raw synced Plaid accounts and transactions are excluded from Mia/OpenRouter prompts and analytics. Only a participant-selected draft summary can enter the existing supervised review context. Logs contain internal record IDs and safe error codes, never Plaid tokens, Plaid transaction IDs, or raw API responses.

## Disconnect and retention

Disconnect calls Plaid `/item/remove` before local credentials are discarded, preventing continued billing and access. The encrypted access token, synced accounts, and Plaid transaction source rows are then removed. Participant-confirmed household transactions remain because they are user-approved financial records; unapproved source data does not.

## Operational controls

- Production requires HTTPS, server-only Plaid credentials, and a distinct 32-byte data-encryption key.
- Webhooks are accepted only after Plaid JWT and request-body hash verification.
- Household scoping is applied to every Item, account, transaction, staging, sync, and disconnect path.
- Access is limited to the owner/operator and authenticated household members according to application roles.
- Review this flow at least annually and after material vendor, product, or storage changes.
