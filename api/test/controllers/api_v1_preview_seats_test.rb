# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"
require_relative "../support/savings_daily_test_support"
require Rails.root.join("db/migrate/20261111090000_allow_staff_preview_seats")
require Rails.root.join("db/migrate/20261111110000_let_ended_staff_previews_rejoin")

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

  test "the server decides which admin sections each person sees, from the same policies the APIs use" do
    keys = ->(user, workspace = nil) { me(user, workspace).fetch("admin_sections").map { |section| section["key"] } }
    all = %w[today people groups coaching reports support settings]
    assert_equal all, keys.call(@admin)
    assert_equal all, keys.call(@owner, @workspace)
    # Coaches who are only on the workspace see just what their role can read.
    assert_equal %w[coaching], keys.call(@editor, @workspace)
    assert_equal %w[coaching], keys.call(@reviewer, @workspace)
    assert_equal %w[coaching], keys.call(@viewer, @workspace)
    # Being a coach of a group adds Today; a reviewer who coaches it adds Reports.
    CohortMembership.create!(cohort: @savings_cohort, user: @editor, role: "coach")
    CohortMembership.create!(cohort: @savings_cohort, user: @reviewer, role: "coach")
    assert_equal %w[today coaching], keys.call(@editor, @workspace)
    assert_equal %w[today coaching reports], keys.call(@reviewer, @workspace)
    assert_equal [], keys.call(@savings_user)
    assert_equal [ "full" ], me(@owner, @workspace).fetch("admin_sections").map { |section| section["access"] }.uniq
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

  # --- a seat ends with the right to it --------------------------------------------------

  test "an editor who previews a group and is then removed from the workspace no longer resolves it" do
    seat = PreviewSeats.join!(user: @editor, cohort_id: @savings_cohort.id)
    get "/api/v1/workspace", headers: auth(@editor).merge("X-Cohort-Id" => @savings_cohort.id.to_s)
    assert_equal @savings_cohort.id, response.parsed_body.dig("workspace", "cohort", "id")

    @workspace.coach_workspace_memberships.find_by!(user: @editor).destroy!

    get "/api/v1/workspace", headers: auth(@editor).merge("X-Cohort-Id" => @savings_cohort.id.to_s)
    assert_response :unprocessable_entity, "the group must not resolve once the right to it is gone"
    assert_equal "cohort_selection_invalid", response.parsed_body["code"]
    assert_not CohortMembership.seats.exists?(id: seat.id), "no reader sees the seat"
    assert_not CohortMembership.live_previews.exists?(id: seat.id)
    assert_empty me(@editor).fetch("preview_groups"), "the row is ended too, so there is nothing left to list"
  end

  test "removing a coach from the workspace ends their preview seat and withdraws an open challenge preview" do
    seat = PreviewSeats.join!(user: @editor, cohort_id: @savings_cohort.id)
    enrollment = preview_enroll(@editor, seat: seat)
    @workspace.coach_workspace_memberships.find_by!(user: @editor).destroy!
    assert_equal "withdrawn", enrollment.reload.status
    assert_equal "preview_ended", CohortMembership.with_previews.find(seat.id).role
    assert_not_includes SavingsEnrollment.counted.pluck(:id), enrollment.id
  end

  test "a seat that cannot be ended yet is listed as no longer available, and can still be left" do
    seat = PreviewSeats.join!(user: @editor, cohort_id: @savings_cohort.id)
    # Ending is the normal path; this is the safety net if a row is ever left behind.
    CoachWorkspaceMembership.where(user: @editor).delete_all
    group = me(@editor).fetch("preview_groups").find { |row| row["cohort_id"] == @savings_cohort.id }
    assert_equal({ "seated" => true, "available" => false }, group.slice("seated", "available"))
    get "/api/v1/workspace", headers: auth(@editor).merge("X-Cohort-Id" => @savings_cohort.id.to_s)
    assert_response :unprocessable_entity
    delete "/api/v1/preview_seats/#{@savings_cohort.id}", headers: auth(@editor)
    assert_response :success
    assert_not CohortMembership.with_previews.exists?(id: seat.id)
    assert_empty response.parsed_body.fetch("preview_groups")
  end

  test "archiving a group ends its preview seats and withdraws a challenge preview" do
    seat = PreviewSeats.join!(user: @admin, cohort_id: @savings_cohort.id)
    enrollment = preview_enroll(@admin, seat: seat)
    @savings_cohort.update!(status: "archived")
    assert_equal "withdrawn", enrollment.reload.status
    assert_not CohortMembership.live_previews.exists?(id: seat.id)
    assert_equal "preview_ended", CohortMembership.with_previews.find(seat.id).role
    get "/api/v1/workspace", headers: auth(@admin).merge("X-Cohort-Id" => @savings_cohort.id.to_s)
    assert_response :unprocessable_entity
  end

  test "a demoted admin or a revoked coach keeps no usable seats" do
    other = other_program_group
    admin_seat = PreviewSeats.join!(user: @admin, cohort_id: other.id)
    @admin.update!(role: "coach")
    assert_not CohortMembership.seats.exists?(id: admin_seat.id), "a coach with no place in that program has no right to its seat"
    get "/api/v1/workspace", headers: auth(@admin).merge("X-Cohort-Id" => other.id.to_s)
    assert_response :unprocessable_entity

    seat = PreviewSeats.join!(user: @editor, cohort_id: @savings_cohort.id)
    @editor.update!(invitation_status: "revoked")
    assert_not CohortMembership.seats.exists?(id: seat.id)
    assert_empty PreviewSeats.visible_cohorts(@editor)
  end

  test "the SQL that honours a seat and the visible-groups list never disagree" do
    other = other_program_group
    @savings_cohort.coach_workspace.cohorts.create!(name: "Archived group", status: "archived", created_by_user: @owner)
    [ @admin, @owner, @editor, @viewer, @outsider ].each do |user|
      visible = PreviewSeats.visible_cohorts(user).pluck(:id)
      Cohort.find_each do |cohort|
        seat = CohortMembership.with_previews.create!(cohort: cohort, user: user, role: "preview")
        assert_equal visible.include?(cohort.id), CohortMembership.live_previews.exists?(id: seat.id), "#{user.role} #{cohort.name}"
        seat.destroy!
      end
    end
    assert other.persisted?
  end

  # --- positive counting and the migrations -----------------------------------------------

  test "counted is positive: an enrollment whose membership is missing or not a participant's is not counted" do
    enrollment = enroll_peer(@peers.first)
    assert_includes SavingsEnrollment.counted.pluck(:id), enrollment.id
    membership = CohortMembership.find(enrollment.accepted_cohort_membership_id)
    membership.update_columns(role: "coach")
    assert_not_includes SavingsEnrollment.counted.pluck(:id), enrollment.id, "an odd role fails closed"
    membership.delete
    assert_not_includes SavingsEnrollment.counted.pluck(:id), enrollment.id, "a lost membership fails closed"

    preview = preview_enroll(@admin)
    CohortMembership.with_previews.where(id: preview.accepted_cohort_membership_id).delete_all
    assert_not_includes SavingsEnrollment.counted.pluck(:id), preview.id, "a lost preview row never makes a preview count"
    assert preview.reload.preview?
  end

  test "rolling the preview migrations back is refused while any preview data exists" do
    seat = PreviewSeats.join!(user: @admin, cohort_id: @savings_cohort.id)
    assert_raises(ActiveRecord::IrreversibleMigration) { run_migration(AllowStaffPreviewSeats, :down) }
    enrollment = preview_enroll(@admin, seat: seat)
    assert_raises(ActiveRecord::IrreversibleMigration, "a preview enrollment blocks the rollback even if its seat row is gone") do
      CohortMembership.with_previews.where(id: seat.id).delete_all
      run_migration(LetEndedStaffPreviewsRejoin, :down)
    end
    assert enrollment.reload.preview?
  end

  test "rolling the preview migrations back and forward works on a clean database" do
    assert_nothing_raised do
      run_migration(LetEndedStaffPreviewsRejoin, :down)
      run_migration(AllowStaffPreviewSeats, :down)
      run_migration(AllowStaffPreviewSeats, :up)
      run_migration(LetEndedStaffPreviewsRejoin, :up)
    end
    SavingsEnrollment.reset_column_information
    CohortMembership.reset_column_information
    assert_includes SavingsEnrollment.column_names, "staff_preview"
  end

  test "a person holding two roles in a group blocks the first rollback" do
    run_migration(LetEndedStaffPreviewsRejoin, :down)
    CohortMembership.create!(cohort: @savings_cohort, user: @editor, role: "coach")
    CohortMembership.create!(cohort: @savings_cohort, user: @editor, role: "participant") # duplicate roles are newly allowed
    assert_raises(ActiveRecord::IrreversibleMigration) { run_migration(AllowStaffPreviewSeats, :down) }
  ensure
    SavingsEnrollment.reset_column_information
  end

  # --- a withdrawn preview never blocks the real thing ------------------------------------

  test "someone who previewed and left can later join the challenge as a real participant" do
    seat = PreviewSeats.join!(user: @editor, cohort_id: @savings_cohort.id)
    preview = preview_enroll(@editor, seat: seat)
    PreviewSeats.leave!(user: @editor, cohort_id: @savings_cohort.id)
    assert_equal "withdrawn", preview.reload.status

    @workspace.coach_workspace_memberships.find_by!(user: @editor).destroy!
    @editor.update!(role: "participant")
    CohortMembership.create!(cohort: @savings_cohort, user: @editor, role: "participant")
    real = enroll_peer(@editor)

    assert_not_equal preview.id, real.id
    assert_not real.preview?
    assert_includes SavingsEnrollment.counted.pluck(:id), real.id
    assert_not_includes SavingsEnrollment.counted.pluck(:id), preview.id
    assert_equal real.id, SavingsEnrollment.in_use.find_by!(user: @editor, cohort: @savings_cohort).id, "lookups find the real enrollment, not the old preview"
    assert_equal "withdrawn", preview.reload.status, "the old preview keeps its history"
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation, "a real enrollment is still one per person") { enroll_peer(@editor) }
  end

  test "someone who previewed, left and previewed again can join the challenge again" do
    first = preview_enroll(@editor)
    PreviewSeats.leave!(user: @editor, cohort_id: @savings_cohort.id)
    assert_equal [ false, false ], me_group(@editor).values_at("seated", "challenge_joined"), "after leaving, nothing is held and the challenge can be joined"

    again = preview_enroll(@editor)
    assert_not_equal first.id, again.id
    assert_equal "active", again.status
    assert_equal [ true, true ], me_group(@editor).values_at("seated", "challenge_joined")
    assert_equal again.id, SavingsEnrollment.in_use.find_by!(user: @editor, cohort: @savings_cohort).id
    assert_equal [ "withdrawn", "active" ], [ first.reload.status, again.status ]
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation, "an open preview cannot be joined twice") { preview_enroll(@editor, seat: CohortMembership.with_previews.find(again.accepted_cohort_membership_id)) }
  end

  test "ended preview rows never block deleting a person or a group" do
    seat = PreviewSeats.join!(user: @viewer, cohort_id: @savings_cohort.id)
    seat.update_columns(role: CohortMembership::ENDED_PREVIEW_ROLE)
    @viewer.coach_workspace_memberships.destroy_all
    assert_difference -> { CohortMembership.with_previews.count }, -1 do
      @viewer.destroy!
    end

    seat = PreviewSeats.join!(user: @admin, cohort_id: @savings_cohort.id)
    seat.update_columns(role: CohortMembership::ENDED_PREVIEW_ROLE)
    group = @workspace.cohorts.create!(name: "Doomed", status: "draft", created_by_user: @owner)
    ended = CohortMembership.with_previews.create!(cohort: group, user: @admin, role: "preview")
    ended.update_columns(role: CohortMembership::ENDED_PREVIEW_ROLE)
    CohortExperienceConfiguration.where(cohort_id: group.id).delete_all
    group = Cohort.find(group.id)
    assert_difference -> { CohortMembership.with_previews.count }, -1 do
      group.destroy!
    end
  end

  # --- reports ----------------------------------------------------------------------------

  test "four participants plus one preview stay suppressed in the sponsor report" do
    four = [ @savings_user ] + @peers.first(3)
    four.each { |user| enroll_peer(user) }
    preview_enroll(@admin)
    exporter = ChallengePrivacy::SponsorExports.new(@savings_cohort, user: @owner)
    assert_equal 4, exporter.send(:enrollments).count, "the preview is not a fifth person"
    provenance = exporter.send(:current_provenance)
    assert_equal 4, provenance[:participants].length
    assert_not_includes provenance[:participants].map { |row| row[:user_id] }, @admin.id
    observations = exporter.send(:enrollments).map { |enrollment| { enrollment_id: enrollment.id, band: "at_target" } }
    report = exporter.send(:build_report, observations, provenance, 30, Date.current, suppress_changes: false)
    assert_equal true, report.fetch(:suppressed)
    assert_equal [], report.fetch(:bands)
    assert_equal "suppressed", report.fetch(:active_consent_count_range)
  end

  test "a platform administrator reads a sealed sponsor report, and each participant it covers gets an audit record" do
    export = seal_report!
    get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports", headers: auth(@admin)
    assert_response :success
    assert_equal false, response.parsed_body.fetch("can_seal")
    assert_difference -> { ChallengePrivacyRead.where(purpose: "admin_sponsor_report", actor_user: @admin).count }, SavingsEnrollment.counted.where(cohort: @savings_cohort).count do
      get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports/#{export.id}", headers: auth(@admin)
      assert_response :success
    end
    assert_no_difference -> { ChallengePrivacyRead.where(actor_user: @owner).count } do
      get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports/#{export.id}", headers: auth(@owner)
      assert_response :success
    end
    post "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports", params: { accepted: true, checkpoint_day: 30 }, headers: auth(@admin), as: :json
    assert_response :forbidden, "sealing stays with the program's owner and reviewer"
    get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports/#{export.id}", headers: auth(@editor)
    assert_response :forbidden
    get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/sponsor_exports/#{export.id}", headers: auth(@savings_user)
    assert_response :forbidden
  end

  test "an admin who is also on the program team reads the roster as the program, without an admin audit" do
    CohortMembership.create!(cohort: @savings_cohort, user: @admin, role: "coach")
    @workspace.coach_workspace_memberships.find_or_create_by!(user: @admin) { |membership| membership.role = "viewer" }
    assert_no_difference -> { ChallengePrivacyRead.where(purpose: "admin_roster").count } do
      get "/api/v1/challenge_cohorts/#{@savings_cohort.id}/participants", params: { view: "daily" }, headers: auth(@admin)
      assert_response :success
    end
    assert_equal :program, ChallengePrivacy::Access.roster!(@savings_cohort, @admin)
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


  def me_group(user)
    me(user).fetch("preview_groups").find { |group| group["cohort_id"] == @savings_cohort.id }
  end

  def run_migration(migration_class, direction)
    ActiveRecord::Migration.suppress_messages { migration_class.new.migrate(direction) }
  end

  # A sealed report whose provenance matches the group today, so reading it is allowed.
  def seal_report!
    @peers.first(2).each { |user| enroll_peer(user) }
    provenance = ChallengePrivacy::SponsorExports.new(@savings_cohort, user: @owner).send(:current_provenance).deep_stringify_keys
    ChallengeSponsorExport.create!(cohort: @savings_cohort, checkpoint_day: 30, policy_version: ChallengePrivacy::SponsorExports::POLICY_VERSION,
      approved_by_user: @owner, resolved_cutoff_on: Date.new(2026, 10, 30), private_provenance: provenance.merge("observations" => []),
      report: { "suppressed" => true, "bands" => [] }, digest: "digest", created_at: Time.current)
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
