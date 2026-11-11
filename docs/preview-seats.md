# Staff use the app: preview seats and the Admin side

Coaches and admins (Mrs. Mel and Bethany are admins in production) use exactly the
app a participant uses, with their own household. Two things sit on top of it.

## Use the app as

Under **Account**, staff choose **My household** or any group they can see
(admins: every group that is not archived; coaches: the groups of their coach
workspaces). Choosing a group takes a **preview seat** in it: that group's voice,
tools, branding and, for a savings group, its challenge, on their own household.
The page header says plainly, for example "Using: Bank of Guam 90 day savings · Preview".

`GET /api/v1/auth/me` returns `preview_groups` (what a person may use, and whether
they hold a seat). `POST /api/v1/preview_seats` takes a seat; `DELETE
/api/v1/preview_seats/:cohort_id` leaves it. Leaving ends an open challenge preview
as a withdrawal. A new seat can join the challenge again. Staff are in "My household" until the
client sends `X-Cohort-Id` for a seat they hold.

A seat is only as good as the right to it. Every reader goes through
`CohortMembership.seats` / `live_previews`, which honour a preview only while its
holder is still an unrevoked coach or admin, the group is not archived and (for a
coach) they are still on the group's coach workspace. When that right ends, the seat
ends too, with the normal `leave!` so an open challenge preview is withdrawn:

- a coach workspace membership is destroyed (`CoachWorkspaceMembership` after commit);
- a person's role or access changes (`Admin::UsersController#update`);
- a group is archived (`Cohort` after commit).

If a row is ever left behind, `preview_groups` lists it with `available: false`
("No longer available") so it can always be left.

## A preview seat is never counted

A preview seat is a `cohort_memberships` row with the role `preview` (one row is
allowed per cohort, user and role, so a coach can also preview the group they coach).
It fails closed:

- `CohortMembership` has a default scope that leaves `preview` and `preview_ended`
  out. Every plain query, `user.cohort_memberships` and `cohort.cohort_memberships`
  included, excludes them. Code that must see a preview asks for it by name:
  `seats`, `previews`, `all_previews`, `with_previews`.
- `savings_enrollments.accepted_cohort_membership_id` points at the membership. Every
  query that counts people over a cohort's enrollments (rosters, counts, the
  30-place cap, the sponsor export, reminders) goes through `SavingsEnrollment.counted`.
  `counted` is defined **positively**: not a staff preview, and accepted through a
  membership whose role is `participant`. A missing or odd membership (a lost
  row, a changed role) is simply not counted.
- A seat that is left keeps its row as `preview_ended` when an enrollment still
  points at it, so that enrollment can never be mistaken for a participant's. Ended
  seats are history, so any number may sit side by side (preview, leave, preview,
  leave): the unique index on (cohort, user, role) is partial and skips
  `preview_ended`, as does the matching validation. Every other role keeps exactly
  one row per person and group, and each ended row keeps its own id for the enrollment
  that points at it. (Re-pointing one shared ended row was rejected: it would rewrite
  an enrollment's accepted membership, which the ledgers treat as frozen identity.)
- Ending a seat is bookkeeping and never stands in the way of losing access.
  Revoking, demoting, archiving a group and removing a coach from a workspace all
  go ahead whatever happens to the seat: `PreviewSeats.release_safely` ends it in a
  savepoint, and if that fails the error is logged and sent to Sentry. The readers
  already ignore a seat its holder has no right to, so a lingering row grants nothing.
  The after-commit hooks (`Cohort`, `CoachWorkspaceMembership`) therefore cannot
  turn a committed change into an error response.
- `savings_enrollments.staff_preview` marks an enrollment accepted through a
  preview seat. It is part of the enrollment's frozen identity (the database
  refuses any change after creation), so it can never flip a person in or out of
  the counts. The unique index on (cohort, user) ignores only a *withdrawn*
  staff preview, so someone who previewed and left can later join for real (a
  coach added as a participant) or preview again. Everyone else keeps one
  enrollment per group; a withdrawn participant enrollment still cannot be replaced.
  The old preview enrollment keeps its id, so ledgers that point at it stay valid.
  Lookups of "this person's enrollment in this group" use `SavingsEnrollment.in_use`,
  which skips an ended staff preview.
- The first two migrations roll back only on a clean database: `down` raises
  `IrreversibleMigration` while preview seats, a person holding two roles in a
  group, or staff preview enrollments exist (rolling back would make them count).
  The partial index migration refuses to roll back while a person has several ended
  seats in one group.
- `preview_ended` rows are removed with the person or group (`dependent: :destroy`).
- A preview enrollment does not make the staff member's own household a participant
  household (`PrivateFinanceAccess.pilot_household?` looks at counted enrollments).
- Staff never reach a participant's pilot household (`User#household_seat_in?`).
- The optional-debt guard in the database accepts the preview seat an enrollment was
  accepted through. The rollout and release-exposure triggers still require
  `participant`, so a preview is never planned into a rollout.

When you add a query over `cohort_memberships` or `savings_enrollments`, decide
whether it means "people in the program" (use the default scope and `counted`) or
"the person using the app" (ask for the seat).

## The Admin side

`/admin/<section>` has a sidebar from 1024px and a section menu on phones.
`GET /api/v1/auth/me` returns `admin_sections` (`AdminSections.for`), so the client
never works out roles:

| Section | Admin | Program owner | Coach with a role in the workspace |
|---|---|---|---|
| Today | yes | yes | if they coach a group in it |
| People | yes | yes | no |
| Groups | yes | yes | no |
| Coaching | yes | yes | yes (every role) |
| Reports | yes (read) | yes | reviewer, if they coach a group in it |
| Support | yes | yes | no |
| Settings | yes | yes | no |

A section is listed only when its main read succeeds: `AdminSections` asks the same
policies the controllers do (`ParticipantRosterPolicy`, `PersonaStudioPolicy`,
`ChallengePrivacy::Access.staff_allowed?`, `CoachWorkspace#allows?`), and
`api_v1_admin_sections_test.rb` checks that every listed section answers 200 for
every kind of staff member. A platform administrator may read sponsor reports for
any group: coarse, groups of five or more, and each participant covered gets an
audit record (`admin_sponsor_report`). Sealing a report stays with the group's owner
and reviewer.

Each section's own APIs still enforce their permissions (see
`api_v1_admin_role_matrix_test.rb`). Old `#Admin` and `#Coach Studio` links redirect
to their sections.
