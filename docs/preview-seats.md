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
as a withdrawal; it cannot be restarted. Staff are in "My household" until the
client sends `X-Cohort-Id` for a seat they hold.

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
- A seat that is left keeps its row as `preview_ended` when an enrollment still
  points at it, so that enrollment can never be mistaken for a participant's.
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

| Section | Admin | Program owner | Editor | Reviewer | Viewer |
|---|---|---|---|---|---|
| Today | yes | yes | yes | yes | yes |
| People | yes | yes | read only | read only | read only |
| Groups | yes | yes | read only | read only | read only |
| Coaching | yes | yes | yes | yes | no |
| Reports | yes | yes | no | yes | no |
| Support | yes | yes | yes | yes | yes |
| Settings | yes | yes | no | no | no |

Each section's own APIs still enforce their permissions (see
`api_v1_admin_role_matrix_test.rb`). Old `#Admin` and `#Coach Studio` links redirect
to their sections.
