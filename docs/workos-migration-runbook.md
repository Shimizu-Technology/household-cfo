# WorkOS migration and enterprise onboarding

This migration changes authentication and enterprise admission. Household calculations, Mia approvals, uploads, private memories, coach permissions, and the 30-person BOG savings challenge remain application responsibilities. The challenge remains $500 saved over 90 days.

## Identity contract

Rails `users.id` is permanent. `authentication_identities` maps a provider, issuer, and subject to that user. The existing `clerk_id` remains for compatibility during the rollback window; it is not a WorkOS subject. `/api/v1/auth/me` reports the verified active `auth_provider` and `auth_subject`.

Pending invitations can accept a server-verified WorkOS identity with a verified matching email. Accepted accounts require an explicit reviewed mapping. Email equality alone must never merge accepted accounts, resolve uniqueness conflicts, or transfer private data. A different personal/work email requires an operator-reviewed identity decision.

No financial records or document contents belong in WorkOS metadata, logs, URLs, OAuth state, or directory attributes.

## Provider configuration

Use a Household CFO WorkOS project with separate staging and production environments. Do not alter another product's environments. Use AuthKit for normal invited login, SAML for enterprise login, Directory Sync for provisioning, and organization-scoped Admin Portal sessions for IT configuration.

Rails selects `AUTH_PROVIDER=clerk|workos`; the frontend selects `VITE_AUTH_PROVIDER=clerk|workos`. Keep both on Clerk during additive deployment. Unknown/missing production authentication configuration fails closed. WorkOS verification requires `WORKOS_CLIENT_ID`, server-only `WORKOS_API_KEY`, trusted API hostname/issuer, client-bound JWKS, valid signature/expiry/subject/session claims, and application authorization.

AuthKit currently mints client-specific issuers such as `https://api.workos.com/user_management/client_…`. The verifier defaults to the configured API origin plus `/user_management/<WORKOS_CLIENT_ID>`. Confirm the actual signed token issuer before binding identities; an explicitly configured legacy issuer is pinned, never inferred from unverified token claims. Some reference examples still show the bare API origin.

For the React integration, configure the production custom authentication API domain before enterprise connection metadata is exchanged. Set `VITE_WORKOS_CLIENT_ID` and `VITE_WORKOS_API_HOSTNAME` to the matching environment/application. Never put an API key in a Vite variable. Production must use the secure cookie refresh flow; SDK development mode is restricted to local development.

The app hostname must share the Authentication API's parent domain so the SDK can read its session-presence cookie and refresh securely. The canonical domain and its managed subdomains are supported. An unrelated vanity domain or Netlify preview hostname requires a separate same-site authentication deployment or a server-side session integration; it must not enter a login loop or use production localStorage tokens. Before activating WorkOS, inventory every active program domain and test its actual cookies. The current production inventory contains no custom program-domain records.

Allow exact frontend origins for AuthKit CORS. Register exact `/auth/callback` callback URLs, sign-out URLs, and `/login` as the initiate-login URI. Verify `/login` actually starts the hosted flow before registering it. The app preserves approved section destinations and `/organization-access`; arbitrary query text and external redirects are excluded. The existing Plaid OAuth callback reference stays in the originating tab, separate from plaintext OAuth state.

Normal app invitations and AuthKit invitations must agree on admission. Disable public signup for production and validate invitation/email-verification flows end to end before cutover. Use WorkOS-native invitation semantics where needed; an application welcome email alone does not necessarily permit invite-only AuthKit registration.

## Account preservation and cutover

1. Inventory actual production users, accepted invitations, local IDs, provider subjects, household/membership relationships, and privileged roles. Do not assume there are exactly three users without checking.
2. Take a recoverable backup and rehearse additive schema upgrades on an isolated database. Retain private inventory outside Git and public PRs.
3. Prepare verified WorkOS identities for the existing users without creating new Rails users. Do not send invitations or change a person's credentials without the corresponding user authorization.
4. Dry-run `auth:workos:bind` with explicit `USER_ID`, `WORKOS_USER_ID`, and `EXPECTED_CLERK_ID`. The task checks the provider profile and identity conflict; `APPLY=true` performs the reviewed association.
5. Run `auth:workos:readiness`; every accepted user must have the intended mapping. Verify internal IDs and financial/chat/document relationships before and after, including role and cohort memberships.
6. Deploy the compatible backend first. Keep the public frontend on Clerk while WorkOS configuration and identity mappings are checked.
7. Complete real hosted login on staging and production for the authorized test users, including mobile Safari cookies, expired sessions, denial, retry, and sign-out.
8. Coordinate a bounded cutover: select WorkOS on the backend, activate the matching frontend, require fresh login, and verify each existing account. Do not treat old cached frontend identity as authorization.
9. Monitor failed login, incorrect organization selection, authorization denials, JWKS/profile/session failures, and provisioning lag. Retire Clerk only after the observation window and successful rollback rehearsal.

Rollback changes authentication configuration and identity mappings; it does not restore an old financial database over newer work. Existing mapped users retain their Clerk association. New accounts first accepted under WorkOS may require an explicit Clerk association if rollback is needed. Never restore a general password/Clerk fallback for an SSO-restricted enterprise member.

## BOG organization and provisioning

A WorkOS organization maps to an application enterprise organization and coaching workspace. A directory group maps explicitly to an eligible cohort. Provisioning grants participant membership only; it never grants global admin, coaching, publication, support, or household finance permission. WorkOS IT contacts are not WorkOS dashboard team members and are not platform administrators.

AuthKit Directory Provisioning currently requires WorkOS enablement. Confirm it is enabled and prove directory-to-AuthKit membership behavior before turning on the corresponding application flag. Match users using verified provider identity and stable directory identifiers; do not recreate local users after reactivation or email changes.

Enable `WORKOS_SYNC_ENABLED` only after the provider configuration and approved participant group mappings are verified. The existing queue execution owner runs synchronization. Persist the Events API cursor only after successful processing, tolerate replay/duplicates, reconcile complete snapshots, and expose failures. Deactivation denies access without deleting financial history. Local revocation remains authoritative, even while short-lived verified provider-state caches are valid.

Test removal from an assigned group, application unassignment, deactivation, and reactivation separately. Okta suspension does not itself send the same provisioning status change as deactivation. Directory deletion is not equivalent to removing every user; detect and investigate it without granting access through a password fallback.

The initial operational target is synchronization within 60 seconds after an event becomes available in WorkOS. Measure it using real provider events; queue/API outages can prevent that target. Existing session access must be checked against current application admission and the enterprise SSO policy.

## Admin Portal and IT packet

Use a revocable dashboard setup link for initial IT onboarding. These expire after 30 days or successful completion. In-app management generates a fresh five-minute portal session and redirects immediately; do not email API-generated links. Allow only exact approved return URLs and provider/custom portal hostnames. Portal URLs are credentials and must not appear in logs or analytics.

The `/organization-access` page is available without loading a household, after backend identity verification. Only platform administrators or explicitly designated IT administrators can configure authorized organizations. IT can inspect connection/synchronization status and open the portal; participant enrollment group mappings and IT grants remain platform-admin operations.

Before sending BOG a setup link, assemble the tested IT packet: verified domains, SAML metadata instructions, SCIM setup, approved assignment/push groups, identity attribute requirements, guest coach policy, offboarding procedure, synchronization expectations, test accounts, support contact, and recovery steps. Okta assignment groups and push groups must follow Okta's documented distinction. Bank IT must confirm the actual employee/guest policy and test its real IdP connection.

## Required verification evidence

- Existing user IDs, roles, households, chats, documents, memories, enrollments, savings evidence and approvals are preserved.
- Valid signed WorkOS JWTs succeed; wrong client/issuer/key, missing session, expiry, malformed claims, and invalid tokens fail closed. Provider outage is distinct from invalid authentication.
- Pending, revoked, accepted-but-unmapped and conflicting users behave correctly, including concurrent linking.
- Non-enterprise invited login, enterprise SSO and the bank application tile reach the intended program. Normal login cannot bypass enterprise policy.
- Directory creation/update/removal/reactivation, group changes, stale snapshots, replay, worker restart, missing events and reconciliation are exercised.
- IT has configuration access only; wrong organization, household, cohort and coaching scopes remain forbidden.
- Desktop, tablet, compact mobile and Safari pass automated browser checks and actual computer-use flows. Dialog headers, dismissal, internal scrolling, focus, loading and error controls remain usable.
- Existing financial/Mia/manual tools/upload/Plaid/coach/admin regression suites pass on the final reviewed commit.
- Required CI checks and material reviewer findings are resolved on that same commit; deployment and production authentication are verified separately.

Official references: [React integration](https://workos.com/docs/authkit/react), [sessions](https://workos.com/docs/authkit/sessions), [Admin Portal](https://workos.com/docs/admin-portal), [Directory Provisioning](https://workos.com/docs/authkit/directory-provisioning), [Events API](https://workos.com/docs/events/data-syncing), [Okta SAML](https://workos.com/docs/integrations/okta-saml), [Okta SCIM](https://workos.com/docs/integrations/okta-scim).
