# Admin console

Household CFO includes a browser-based Admin side for owner admins and coaches. This avoids local `rails runner` invite commands during testing and gives Mrs. Mel/Leon the foundation for pilot cohort operations.

## Owner bootstrap

`bin/rails db:seed` creates a default admin invite when one is missing for:

```text
shimizutechnology@gmail.com
```

The seed is invite-only. The admin signs in through WorkOS (email code or Google) using that same email. On first sign-in, the API links the verified WorkOS identity to the pending local admin record. Re-running seeds fills missing bootstrap fields, but it does not undo an intentional role/status change made through the admin UI.

Additional bootstrap admins can be added when seeding:

```bash
SEED_ADMIN_EMAILS=owner@example.com,partner@example.com bin/rails db:seed
```

## The Admin side

Updated: 2026-11-11 (round 5, slice A2, fix round 1)

`/admin/<section>` is where Mrs. Mel, Bethany and any coach run their groups. A phone gets a section menu and rows; a desktop gets a sidebar and tables. What each person sees comes from `/auth/me` (`admin_sections`; see `docs/preview-seats.md`). Every screen says **group**, never "cohort"; code identifiers keep the old name.

| Section | What it is | Where it lives |
|---|---|---|
| Today | One group's people for today: Everyone / Need you / Checked in / No check-in today (or Invited / Joined / Setup done for a household group), a name search, "Show more" paging and View person for anyone, with the server's counts. The group opens on whoever needs you. Then invitations that went nowhere (with "Send again"; owners only) and each group's state. Works for every role the server gives Today: owners, admins, and editors, reviewers and viewers on a group's team (who read the groups they may see and never the owner-only lists) | `web/src/admin/sections/TodaySection.tsx` |
| People | Table on desktop (name, group, role, invitation, last active, setup; name and last active sort), compact rows on phones, filters by group, role (when staff are listed) and Joined / Invited / Email didn't arrive / Removed, sorting by name, email, invitation, last active or setup. One **Invite people** action takes one or many emails and asks "Invite 3 people to <group>?" before sending; a group is only preselected when there is one. A person opens to resend, add to another group (or move, when they are in one group), change role (admins), cancel a pending invitation, or remove from a group | `PeopleSection`, `InvitePeople`, `PersonDetail` |
| Groups | List with status, dates and who has joined. Archived groups are behind "Show archived groups" and come back by changing where they stand. A group opens to its challenge (open and pause, with a recorded reason), details, the week in a sentence (people, questions to Mia, uploads, anything that failed), coach voice and the tools people can open, in order, with earlier versions to go back to | `GroupsSection`, `GroupTools`, `CohortExperienceStudio` (one row per tool) |
| Coaching | Two steps: describe your coach's voice, then preview and go live. **Group tools** (every role that can see Coaching reaches the tools of the groups it may see; the server says what each may do) and **History** (earlier voices, teaching library, group updates, and earlier program looks) sit at the end | `components/CoachStudio.tsx`, `CoachStudioAdvanced.tsx` |
| Reports | Day 30, 60 and 90 per savings group: view, save, download (the file is made from a fresh read checked to be that group's report). Coarse, hidden below five people. Saved reports are followed across pages. Says who can save when this person cannot | `ReportsSection` |
| Support | Setup requests and problem reports in one list, newest first, with status | `SupportSection` |
| Settings | Name and look (saved as a draft; it goes live with Coaching → Go live, and earlier looks are under Coaching → History), team; for admins also programs, who can do what, bank connections, organization access and activity | `SettingsSection`, `BankHealth`, `Activity` |

Words and labels shared by the sections are in `web/src/admin/adminWords.ts` (invitation states, "last active", group lines). The invitation state **Email didn't arrive** is shown only where the server reveals delivery (platform admins); everyone else sees **Invited**.

Activity reads the open and pause records every savings group already keeps, filtered by the group itself. It says so on the screen; it is not a full audit feed.

The program picker is locked while any save is in flight (`useWorkspaceMutationInFlight`, fed by every mutation ticket and by `useHoldWorkspaceLock`).

Admins can:

- create groups, set status, dates and notes,
- invite people as participants, coaches or admins, one or many at a time, by email,
- resend invitation emails,
- move a participant to another group, or remove them from one,
- change a person's role, or remove their access,
- open and pause a group's savings challenge,
- see setup progress in plain words without exposing household financial rows.

A program owner can do the same for participants in their own groups, and opens and pauses their own challenge. A coach with a smaller role sees only the sections the server lists.

Role/group policy is backend-enforced:

- `admin`: a group is optional.
- active `coach`: at least one group is required.
- active `participant`: at least one group is required.
- `revoked` users may have no group, so admins can cancel pending invites or remove someone from their last group.

## API shape

Admin endpoints require a verified WorkOS session.

```text
GET    /api/v1/admin/cohorts
POST   /api/v1/admin/cohorts
GET    /api/v1/admin/cohorts/:id
PATCH  /api/v1/admin/cohorts/:id
GET    /api/v1/admin/users
POST   /api/v1/admin/users
PATCH  /api/v1/admin/users/:id
POST   /api/v1/admin/users/:id/resend_invitation
POST   /api/v1/admin/users/:id/cancel_invitation
```

`cancel_invitation` lets a program owner (or an administrator working inside a program) withdraw a participant's never-accepted invitation when every group the person is in belongs to that program. It revokes the invitation, removes the seats, and writes a `ParticipantInvitationCancellation` (who, whom, which groups). Anything else, such as a person also in another program, stays with the administrator's status change.

`/api/v1/admin/cohorts` is admin-only. User invite management is staff-aware at the API layer; the web shows each person only the sections the server lists. Create/resend responses include `invitation_sent`, `invitation_status`, and `invitation_error` so the UI can report whether Resend actually delivered the email.

## Invitation emails

Invite emails go out through WorkOS invitations, with branded Resend delivery when custom delivery is enabled. The Admin UI sends by default; if delivery is not configured, invites are still created but email delivery is marked `failed` with the missing configuration reason. Admins can explicitly uncheck email delivery when creating an invite; that intentional no-send path is marked `skipped`.

```bash
RESEND_API_KEY=re_...
RESEND_FROM_EMAIL="Household CFO <noreply@example.com>"
# or MAILER_FROM_EMAIL=noreply@example.com
FRONTEND_URL=http://localhost:5173
```

Email delivery metadata is summarized on the invited user (`invitation_email_status`, provider id, last attempt/sent timestamps, and last sender). Each create/resend also writes an immutable `invitation_email_attempts` audit row so admins can retry delivery without losing history or using Rails console commands.

## Safety constraints

- The UI requests real invitation emails by default; missing Resend config is surfaced as a failed delivery instead of looking intentional.
- The UI blocks self-demotion/revocation at the backend.
- The backend prevents removing the last active admin.
- Group views show completion/readiness summaries, not detailed financial entries.
- Do not add real participant financial data to seeds, tests, docs, or screenshots.

## Local blank-slate flow

1. Configure WorkOS staging keys in `api/.env` and `web/.env.local` (or leave them unset for sample-data preview mode).
2. Reset local DB if needed:

   ```bash
   cd api
   bin/rails db:drop db:create db:migrate db:seed
   ```

3. Start Rails and Vite.
4. Sign in with `shimizutechnology@gmail.com`.
5. Open the Admin side (`/admin`).
6. Under Groups, create a test group.
7. Under People, invite a fake participant email into that group.
8. Confirm the invite email arrives. If the UI reports delivery failed because `RESEND_API_KEY` is missing, add the key to `api/.env` and restart Rails before retrying.
9. Sign out, sign in as the participant, and test the blank workspace/setup/Mia flow.
