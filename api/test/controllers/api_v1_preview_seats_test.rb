# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/savings_daily_test_support"

# Staff use the same app a participant does. A preview seat is how they try a
# group out, and it must never be counted: not in a roster, a count, the 30-place
# cap, a report, an export or a reminder.
class ApiV1PreviewSeatsTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include SavingsDailyTestSupport

  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 1, 12)
    setup_savings_context
    @workspace = @savings_cohort.coach_workspace
    @admin = persona_user(role: "admin")
    @owner = @savings_owner
    @editor = staff("coach", workspace_role: "editor")
    @reviewer = staff("coach", workspace_role: "reviewer")
    @viewer = staff("coach", workspace_role: "viewer")
    @outsider = persona_user(role: "coach")
    CoachWorkspaces::Provisioner.ensure_for!(@outsider)
    with_savings_runtime { nil }
    # Five more participants, so the group looks like a small real one.
    @peers = Array.new(5) { |index| participant("Peer #{index}") }
  end
  teardown { travel_back }

  # --- what /auth/me tells each person ---------------------------------------------------

  test "the server decides which admin sections each person sees" do
    keys = ->(user, workspace = nil) { me(user, workspace).fetch("admin_sections").map { |section| section["key"] } }
    all = %w[today people groups coaching reports support settings]
    assert_equal all, keys.call(@admin)
    assert_equal all, keys.call(@owner, @workspace)
    assert_equal %w[today people groups coaching support], keys.call(@editor, @workspace)
    assert_equal %w[today people groups coaching reports support], keys.call(@reviewer, @workspace)
    assert_equal %w[today people groups support], keys.call(@viewer, @workspace)
    assert_equal [], keys.call(@savings_user)
    assert_equal "read_only", me(@editor, @workspace).fetch("admin_sections").find { |section| section["key"] == "people" }.fetch("access")
    assert_equal "full", me(@owner, @workspace).fetch("admin_sections").find { |section| section["key"] == "people" }.fetch("access")
  end

  test "admins may preview any group, coaches the groups of their program, participants none" do
    other = other_program_group
    assert_equal [ @savings_cohort.id, other.id ].sort, me(@admin).fetch("preview_groups").map { |group| group["cohort_id"] }.sort
    assert_equal [ @savings_cohort.id ], me(@owner, @workspace).fetch("preview_groups").map { |group| group["cohort_id"] }
    assert_equal [ @savings_cohort.id ], me(@editor, @workspace).fetch("preview_groups").map { |group| group["cohort_id"] }
    assert_equal [ other.id ], me(@outsider).fetch("preview_groups").map { |group| group["cohort_id"] }
    assert_empty me(@savings_user).fetch("preview_groups")
    @savings_cohort.update!(status: "archived")
    assert_empty me(@owner, @workspace).fetch("preview_groups")
  end

  test "taking a seat is idempotent, limited to visible groups, and refused for participants" do
    other = other_program_group
    post "/api/v1/preview_seats", params: { cohort_id: @savings_cohort.id }, headers: auth(@admin), as: :json
    assert_response :created
    assert_equal true, response.parsed_body.fetch("preview_groups").find { |group| group["cohort_id"] == @savings_cohort.id }.fetch("seated")
    assert_no_difference -> { CohortMembership.with_previews.count } do
      post "/api/v1/preview_seats", params: { cohort_id: @savings_cohort.id }, headers: auth(@admin), as: :json
      assert_response :created
    end
    post "/api/v1/preview_seats", params: { cohort_id: other.id }, headers: auth(@owner), as: :json
    assert_response :not_found
    post "/api/v1/preview_seats", params: { cohort_id: @savings_cohort.id }, headers: auth(@savings_user), as: :json
    assert_response :forbidden
    assert_equal 1, CohortMembership.previews.where(cohort: @savings_cohort).count
    assert_equal "preview", CohortMembership.previews.find_by!(cohort: @savings_cohort, user: @admin).role
  end

  # --- the seat is the app ---------------------------------------------------------------

  test "staff sit in their own household until they choose a group, then get that group's runtime" do
    household = HouseholdFinance::WorkspaceResolver.new(@admin).household
    get "/api/v1/workspace", headers: auth(@admin)
    assert_response :success
    assert_equal household.id, response.parsed_body.dig("workspace", "household_id")
    assert_nil response.parsed_body.dig("workspace", "cohort")

    seat = PreviewSeats.join!(user: @admin, cohort_id: @savings_cohort.id)
    get "/api/v1/workspace", headers: auth(@admin).merge("X-Cohort-Id" => @savings_cohort.id.to_s)
    assert_response :success
    assert_equal household.id, response.parsed_body.dig("workspace", "household_id")
    assert_equal @savings_cohort.id, response.parsed_body.dig("workspace", "cohort", "id")
    get "/api/v1/workspace", headers: auth(@admin)
    assert_nil response.parsed_body.dig("workspace", "cohort"), "back on My household nothing of the group follows"

    runtime = Mia::ParticipantRuntimeResolver.new(user: @admin, cohort_membership: seat).call
    assert_equal seat.id, runtime.membership.id
    assert_equal @savings_cohort.id, runtime.cohort_id
    assert_equal "preview", runtime.membership.role

    get "/api/v1/workspace", headers: auth(@admin).merge("X-Cohort-Id" => other_program_group.id.to_s)
    assert_response :unprocessable_entity
    assert_equal "cohort_selection_invalid", response.parsed_body["code"]
    get "/api/v1/workspace", headers: auth(@outsider).merge("X-Cohort-Id" => @savings_cohort.id.to_s)
    assert_response :unprocessable_entity
  end

  test "a coach can hold a preview seat in the group they coach without losing either" do
    coach_seat = CohortMembership.create!(cohort: @savings_cohort, user: @editor, role: "coach")
    preview = PreviewSeats.join!(user: @editor, cohort_id: @savings_cohort.id)
    assert_equal [ coach_seat.id ], @savings_cohort.cohort_memberships.where(user: @editor).pluck(:id)
    assert_equal [ preview.id ], @editor.preview_seats.pluck(:id)
    assert_equal preview.id, Mia::EffectiveCohortResolver.new(user: @editor, role: @editor.seat_role, requested_cohort_id: @savings_cohort.id).call.id
    @editor.cohort_memberships.where(cohort: @savings_cohort).destroy_all
    assert CohortMembership.previews.exists?(id: preview.id), "removing a coaching seat leaves the preview"
  end

  # --- invisible to programs --------------------------------------------------------------

  test "a preview seat and its challenge enrollment appear in no roster, count, cap, report, export or reminder" do
    with_daily_operations { savings_enroll; savings_plan; savings_approve(savings_draft(12345)); daily_check_in("no_spend") }
    @peers.each { |peer| enroll_peer(peer) }
    full_user = participant("One too many")
    counted_before = counts_snapshot
    @savings_cohort.update!(savings_challenge_capacity: SavingsEnrollment.counted.where(cohort: @savings_cohort).count)

    admin_enrollment = preview_enroll(@admin)
    owner_enrollment = preview_enroll(@owner)
    assert admin_enrollment.preview?
    assert_equal [ admin_enrollment.id, owner_enrollment.id ].sort, SavingsEnrollment.previews.where(cohort: @savings_cohort).pluck(:id).sort
    assert_not_includes SavingsEnrollment.counted.pluck(:id), admin_enrollment.id
    assert_equal counted_before, counts_snapshot

    # The cap is full for real participants, and previews never fill or hit it.
    assert_raises(ArgumentError, "the 30-place cap still applies to participants") { enroll_peer(full_user) }

    # Rosters and counts.
    get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/participants", params: { view: "daily" }, headers: auth(@owner)
    assert_response :success
    ids = response.parsed_body.fetch("records").map { |row| row.dig("participant", "id") }
    assert_not_includes ids, @admin.id
    assert_not_includes ids, @owner.id
    assert_equal counted_before.fetch(:roster), response.parsed_body.dig("counts", "all")
    get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/participants", headers: auth(@owner)
    assert_response :success
    assert_equal [ true ], [ response.parsed_body.fetch("records").none? { |row| row.dig("participant", "id").in?([ @admin.id, @owner.id ]) } ]

    # Admin cohort payloads: counts and member lists.
    get "/api/v1/admin/cohorts/#{@savings_cohort.id}", headers: auth(@admin)
    cohort = response.parsed_body.fetch("cohort")
    assert_equal counted_before.fetch(:participants), cohort.fetch("participant_count")
    assert_equal counted_before.fetch(:members), cohort.fetch("member_count")
    assert_not_includes cohort.fetch("members").map { |member| member.dig("user", "id") }, @admin.id
    assert_equal counted_before.fetch(:participants), cohort.dig("savings_challenge", "participant_count")
    get "/api/v1/admin/users", headers: auth(@admin)
    admin_row = response.parsed_body.fetch("users").find { |row| row["id"] == @admin.id }
    assert_equal [], admin_row.fetch("cohort_ids", []) if admin_row&.key?("cohort_ids")

    # Reminders never go to a preview.
    scheduled = ChallengeReminders::Scheduler.new.call
    assert_equal 0, ChallengeReminder.where(savings_enrollment: SavingsEnrollment.previews).count, scheduled.inspect
    assert_equal "participant_unavailable", ChallengeReminders::Eligibility.new.reason(admin_enrollment, ChallengeReminderPreference.new(enabled: true, local_time: "00:00", channel: "email"))

    # Reports and exports: nothing about a preview in the roster, provenance or observations.
    exporter = ChallengePrivacy::SponsorExports.new(@savings_cohort, user: @owner)
    provenance = exporter.send(:current_provenance)
    assert_not_includes provenance[:participants].map { |row| row[:user_id] }, @admin.id
    assert_not_includes provenance[:participants].map { |row| row[:enrollment_id] }, admin_enrollment.id

    # The roster a platform administrator reads is audited, and still has no previews.
    assert_difference -> { ChallengePrivacyRead.where(purpose: "admin_roster").count }, @peers.length + 1 do # the first participant and five peers
      get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/participants", params: { view: "daily" }, headers: auth(@admin)
      assert_response :success
    end
    assert_not_includes response.parsed_body.fetch("records").map { |row| row.dig("participant", "id") }, @admin.id
  end

  test "a preview seat is not part of rollouts, releases or persona conflicts" do
    seat = PreviewSeats.join!(user: @admin, cohort_id: @savings_cohort.id)
    assert_not_includes CohortRollouts::Contract.participant_user_ids(@savings_cohort), @admin.id
    assert_not_includes Mia::PersonaAssignmentCompatibility.participant_ids_for(cohort: @savings_cohort), @admin.id
    assert_not CohortMembership.where(role: "participant").exists?(id: seat.id)
    assert_not CohortMembership.exists?(id: seat.id), "the default scope leaves previews out of every plain query"
    assert CohortMembership.with_previews.exists?(id: seat.id)
  end

  test "an enrolled preview does not turn the staff member's own household into a participant household" do
    seat = PreviewSeats.join!(user: @admin, cohort_id: @savings_cohort.id)
    household = HouseholdFinance::WorkspaceResolver.new(@admin).household
    preview_enroll(@admin, seat: seat)
    assert_not ChallengePrivacy::PrivateFinanceAccess.pilot_household?(household)
    assert ChallengePrivacy::PrivateFinanceAccess.pilot_household?(@savings_household)
    get "/api/v1/budget", headers: auth(@admin)
    assert_response :success
  end

  test "joining the challenge from a preview seat follows the same release-hold rules as a participant" do
    seat = PreviewSeats.join!(user: @admin, cohort_id: @savings_cohort.id)
    @savings_cohort.update!(savings_challenge_release_hold: true)
    assert_raises(SavingsChallenge::AccessPolicy::Unavailable, "a held challenge cannot be joined, preview or not") { preview_enroll(@admin, seat: seat) }
    assert_equal 0, SavingsEnrollment.where(user: @admin).count
    @savings_cohort.update!(savings_challenge_release_hold: false)
    assert preview_enroll(@admin, seat: seat).preview?
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation, "joining twice is refused") { preview_enroll(@admin, seat: seat) }
  end

  # --- leaving ----------------------------------------------------------------------------

  test "leaving ends an open challenge preview as a withdrawal and says so plainly" do
    seat = PreviewSeats.join!(user: @admin, cohort_id: @savings_cohort.id)
    enrollment = preview_enroll(@admin, seat: seat)
    delete "/api/v1/preview_seats/#{@savings_cohort.id}", headers: auth(@admin)
    assert_response :success
    assert_includes response.parsed_body.fetch("message"), "challenge preview ended"
    assert_equal "withdrawn", enrollment.reload.status
    assert_equal "preview_ended", CohortMembership.with_previews.find(seat.id).role, "the seat's row stays as history for the enrollment"
    assert enrollment.preview?, "an ended preview is still never a participant"
    assert_not_includes SavingsEnrollment.counted.pluck(:id), enrollment.id
    assert_empty @admin.preview_seats
    assert_not ChallengePrivacy::PrivateFinanceAccess.pilot_household?(HouseholdFinance::WorkspaceResolver.new(@admin).household)
    assert_equal false, response.parsed_body.fetch("preview_groups").find { |group| group["cohort_id"] == @savings_cohort.id }.fetch("seated")

    delete "/api/v1/preview_seats/#{@savings_cohort.id}", headers: auth(@admin)
    assert_response :success
    assert_equal PreviewSeats::LEFT_MESSAGE, response.parsed_body.fetch("message")
    get "/api/v1/workspace", headers: auth(@admin).merge("X-Cohort-Id" => @savings_cohort.id.to_s)
    assert_response :unprocessable_entity
  end

  test "a staff member who becomes a participant keeps no preview seats" do
    seat = PreviewSeats.join!(user: @editor, cohort_id: @savings_cohort.id)
    PreviewSeats.release_all!(@editor)
    assert_not CohortMembership.with_previews.exists?(id: seat.id)
    assert_not CohortMembership.new(cohort: @savings_cohort, user: @savings_user, role: "preview").valid?, "participants cannot hold previews"
  end

  # --- every admin API refuses the people who do not have the section ---------------------

  test "admin APIs refuse participants, and sections the role does not have" do
    [ "/api/v1/admin/users", "/api/v1/admin/cohorts", "/api/v1/admin/personas", "/api/v1/admin/pilot_feedback_reports" ].each do |path|
      get path, headers: auth(@savings_user)
      assert_response :forbidden, "participant must not read #{path}"
    end
    headers = ->(user) { auth(user).merge("X-Coach-Workspace-Id" => @workspace.id.to_s) }
    get "/api/v1/admin/cohorts", headers: headers.call(@editor)
    assert_response :forbidden, "editor coaches have no Groups management"
    get "/api/v1/admin/cohorts", headers: headers.call(@viewer)
    assert_response :forbidden
    get "/api/v1/admin/cohorts", headers: headers.call(@owner)
    assert_response :success
    get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports", headers: auth(@owner)
    assert_response :success
    get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports", headers: auth(@editor)
    assert_response :forbidden
    get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/participants", params: { view: "daily" }, headers: auth(@savings_user)
    assert_response :forbidden
    post "/api/v1/admin/cohorts/#{@savings_cohort.id}/challenge_access/pause", params: { challenge_access: { reason: "Participants cannot pause" } },
      headers: auth(@savings_user).merge("Idempotency-Key" => "participant-pause"), as: :json
    assert_response :forbidden
  end

  private

  def auth(user) = { "Authorization" => "Bearer test_token_#{user.id}" }

  def me(user, workspace = nil)
    headers = auth(user)
    headers["X-Coach-Workspace-Id"] = workspace.id.to_s if workspace
    get "/api/v1/auth/me", headers: headers
    assert_response :success
    response.parsed_body.fetch("user")
  end

  def staff(role, workspace_role:)
    persona_user(role: role).tap { |user| @workspace.coach_workspace_memberships.create!(user: user, role: workspace_role) }
  end

  def participant(name)
    user = User.create!(clerk_id: "clerk_peer_#{SecureRandom.hex(6)}", email: "peer-#{SecureRandom.hex(6)}@example.com", first_name: name,
      role: "participant", invitation_status: "accepted")
    CohortMembership.create!(cohort: @savings_cohort, user: user, role: "participant")
    user
  end

  def other_program_group
    @other_program_group ||= begin
      workspace = CoachWorkspace.create!(name: "Other program", slug: "other-#{SecureRandom.hex(3)}", created_by_user: @outsider)
      workspace.coach_workspace_memberships.create!(user: @outsider, role: "owner")
      Cohort.create!(name: "Other group", status: "enrolling", created_by_user: @outsider, coach_workspace: workspace)
    end
  end

  def enroll_peer(user)
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    membership = @savings_cohort.cohort_memberships.find_by!(user: user, role: "participant")
    digest = SavingsChallenge::EnrollmentOffer.call(cohort: @savings_cohort.reload, user: user, membership: membership).fetch(:acceptance_digest)
    HouseholdFinance::Operations::Runner.new(household, user: user, cohort_membership: membership).run(
      operation_key: "savings.enrollment.accept", idempotency_key: SecureRandom.uuid,
      input: { cohort_id: @savings_cohort.id, participation_accepted: true, policy_version: "1", late_start_accepted: true, expected_acceptance_digest: digest }
    ).subject
  end

  def preview_enroll(user, seat: nil)
    seat ||= PreviewSeats.join!(user: user, cohort_id: @savings_cohort.id)
    household = HouseholdFinance::WorkspaceResolver.new(user).household
    digest = SavingsChallenge::EnrollmentOffer.call(cohort: @savings_cohort.reload, user: user, membership: seat).fetch(:acceptance_digest)
    HouseholdFinance::Operations::Runner.new(household, user: user, cohort_membership: seat).run(
      operation_key: "savings.enrollment.accept", idempotency_key: SecureRandom.uuid,
      input: { cohort_id: @savings_cohort.id, participation_accepted: true, policy_version: "1", late_start_accepted: true, expected_acceptance_digest: digest }
    ).subject
  end

  def counts_snapshot
    roster = nil
    with_daily_operations do
      roster = ChallengePrivacy::CoachDailyRoster.new(@savings_cohort.reload, user: @owner).call.dig(:counts, "all")
    end
    {
      participants: @savings_cohort.cohort_memberships.where(role: "participant").count,
      members: @savings_cohort.cohort_memberships.count,
      counted_enrollments: SavingsEnrollment.counted.where(cohort: @savings_cohort).count,
      roster: roster,
      status_count: SavingsChallenge::LaunchControl.new(cohort: @savings_cohort).status.fetch(:participant_count)
    }
  end
end
