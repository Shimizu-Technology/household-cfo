require "test_helper"
require_relative "../support/savings_debt_test_support"

class SetupHelpTest < ActiveSupport::TestCase
  include SavingsDebtTestSupport

  setup do
    @user = create_user("participant")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @admin = create_user("admin")
    @participant = SetupHelp::Participant.new(@household, user: @user)
    @restart = SetupHelp::Restart.new(@household, user: @user)
  end

  test "automatic defaults and empty read-generated annual plans do not block safe unfinished restart" do
    assert_equal SetupHelp::Eligibility::AUTO_GOAL, @household.primary_goal
    HouseholdFinance::DataPresenter.new(@household, user: @user).app_data
    assert @household.budget_years.exists?
    assert_equal 12, @household.budget_years.first.budget_periods.count
    assert @participant.status[:self_restart_available]
    preview = @restart.preview
    assert_equal "self_setup", FinancialRestartReview.find(preview[:review][:id]).purpose
    @restart.apply(review_id: preview[:review][:id], confirmation: "START OVER")
    assert_equal 1, @household.reload.financial_generation
    assert_equal @user.id, @household.household_memberships.first.user_id
    assert_empty @household.confirmed_setup_fields
  end

  test "explicit confirmed zeros and saved inactive facts need support even while setup is incomplete" do
    @household.update!(confirmed_setup_fields: [ "primary_income" ])
    assert_not @participant.status[:setup_complete]
    assert_not @participant.status[:self_restart_available]
    assert_raises(SetupHelp::Error) { @restart.preview }
    @household.update!(confirmed_setup_fields: [])
    @household.income_sources.create!(label: "Earlier job", source_type: "job", cadence: "monthly", amount_cents: 0, active: false)
    assert_not @participant.status[:self_restart_available]
  end

  test "legacy debt confirmations also preserve explicit financial zeros" do
    %w[credit_card_debt debt_payment].each do |field|
      @household.update!(confirmed_setup_fields: [ field ])
      assert_not @participant.status[:self_restart_available]
      assert_raises(SetupHelp::Error) { @restart.preview }
    end
  end

  test "whole-household restart requires owner and explicit shared impact acknowledgment" do
    partner = create_user("participant")
    @household.household_memberships.create!(user: partner, role: "partner")
    assert SetupHelp::Participant.new(@household, user: partner).status[:owner_required]
    assert_raises(SetupHelp::Denied) { SetupHelp::Restart.new(@household, user: partner).preview }
    assert_raises(SetupHelp::Denied) { SetupHelp::Participant.new(@household, user: partner).create_request(reason: "other", share_metadata: true, idempotency_key: "partner") }
    session = @household.chat_sessions.create!(user: partner, rolling_summary: "Private summary")
    message = session.chat_messages.create!(role: "user", content: "Private original conversation")
    review = @restart.preview[:review]
    assert review[:reset_fields].last.include?("every household member")
    assert_raises(HouseholdFinance::FinancialRestart::Flow::Error) { @restart.apply(review_id: review[:id], confirmation: "START OVER") }
    @restart.apply(review_id: review[:id], confirmation: "START OVER", shared_household_acknowledged: true)
    assert_nil session.reload.rolling_summary
    assert ChatMessage.exists?(message.id)
  end

  test "self review never applies after facts were saved and expired canceled reviews cannot restart" do
    review = @restart.preview[:review]
    @household.accounts.create!(label: "Known zero", account_type: "checking", balance_cents: 0)
    assert_raises(SetupHelp::Error) { @restart.apply(review_id: review[:id], confirmation: "START OVER") }
    assert_equal 0, @household.reload.financial_generation
    @household.accounts.first.destroy!
    review = @restart.preview[:review]
    travel 16.minutes do
      assert_raises(HouseholdFinance::FinancialRestart::Flow::StaleReview) { @restart.apply(review_id: review[:id], confirmation: "START OVER") }
    end
    @restart.cancel(review_id: review[:id])
    assert_raises(HouseholdFinance::FinancialRestart::Flow::Error) { @restart.apply(review_id: review[:id], confirmation: "START OVER") }
  end

  test "generation guards stale previews while applied receipt recovery is exact and actor authorized" do
    review = @restart.preview[:review]
    @restart.apply(review_id: review[:id], confirmation: "START OVER")
    @household.income_sources.create!(label: "Fresh real job", source_type: "job", cadence: "monthly", amount_cents: 200_000)
    FinancialPicture.set(household_id: @household.id, generation: 0) do
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { @restart.preview }
      recovered = @restart.apply(review_id: review[:id], confirmation: "START OVER")
      assert_equal "applied", recovered[:review][:status]
    end
    assert_equal 1, @household.reload.financial_generation
    assert_equal 1, @household.income_sources.count
    @user.update!(invitation_status: "revoked")
    assert_raises(SetupHelp::Denied) { @restart.apply(review_id: review[:id], confirmation: "START OVER") }
  end

  test "old administrator facade cannot apply self reviews and new facade cannot read admin test reviews" do
    @user.update!(role: "admin")
    self_review = @restart.preview[:review]
    admin_flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
    assert_raises(ActiveRecord::RecordNotFound) { admin_flow.apply(review_id: self_review[:id], confirmation: "START OVER") }
    admin_review = admin_flow.preview[:review]
    assert_raises(ActiveRecord::RecordNotFound) { @restart.status(review_id: admin_review[:id]) }
    assert_raises(ActiveRecord::RecordNotFound) { @restart.apply(review_id: admin_review[:id], confirmation: "START OVER") }
  end

  test "request creation deduplicates active requests and rejects conflicting idempotency or missing disclosure" do
    assert_raises(SetupHelp::Error) { @participant.create_request(reason: "other", share_metadata: false, idempotency_key: "key") }
    assert_raises(SetupHelp::Error) { @participant.create_request(reason: "other", share_metadata: true, idempotency_key: "") }
    first = request("one")
    assert_equal first[:id], request("one")[:id]
    assert_equal first[:id], request("two", reason: "upload_problem")[:id]
    assert_equal "practice_numbers", @participant.status[:latest_request][:reason]
    assert_raises(SetupHelp::Conflict) { request("one", reason: "wrong_setup") }
    assert_equal 1, @household.setup_support_requests.count
    assert_equal 1, @household.household_audit_events.where(event_type: "setup_support.requested").count
    @participant.cancel_request(id: first[:id], expected_lock_version: first[:lock_version])
    assert_equal first[:id], request("one")[:id]
    assert_not_equal first[:id], request("new-after-cancel")[:id]
  end

  test "ordinary support is shared only with accepted platform admins and never exposes private inventory" do
    first = request
    @household.income_sources.create!(label: "Secret employer", source_type: "job", cadence: "monthly", amount_cents: 987_654)
    coach = create_user("coach")
    assert_empty SetupHelp::Staff.new(user: coach).list[:records]
    assert_raises(ActiveRecord::RecordNotFound) { SetupHelp::Staff.new(user: coach).transition(id: first[:id], action: "triage", expected_lock_version: 0) }
    staff = SetupHelp::Staff.new(user: @admin)
    listed = staff.list[:records].find { |item| item[:id] == first[:id] }
    refute JSON.generate(listed).match?(/Secret employer|987654|inventory|previous_setup|fingerprint/)
    prepared = staff.transition(id: first[:id], action: "prepare", expected_lock_version: 0)[:request]
    assert_equal "ready", prepared[:status]
    refute JSON.generate(prepared).match?(/Secret employer|987654|inventory|previous_setup|fingerprint/)
    assert_equal 0, @household.reload.financial_generation
    assert_equal @user.id, FinancialRestartReview.find(prepared[:review_id]).requested_by_user_id
    assert_equal @admin.id, SetupSupportRequest.find(first[:id]).prepared_by_user_id
  end

  test "supported participant final confirmation preserves records and recovers exact receipt" do
    @household.income_sources.create!(label: "Practice job", source_type: "job", cadence: "monthly", amount_cents: 100_000)
    first = request
    prepared = SetupHelp::Staff.new(user: @admin).transition(id: first[:id], action: "prepare", expected_lock_version: 0)[:request]
    supported = SetupHelp::Restart.new(@household, user: @user, request_id: first[:id])
    assert_equal prepared[:review_id], supported.preview[:review][:id]
    assert_raises(ActiveRecord::RecordNotFound) { @restart.apply(review_id: prepared[:review_id], confirmation: "START OVER") }
    assert_raises(HouseholdFinance::FinancialRestart::Flow::Error) { supported.apply(review_id: prepared[:review_id], confirmation: "YES") }
    supported.apply(review_id: prepared[:review_id], confirmation: "START OVER")
    assert_equal "applied", @participant.status[:latest_request][:status]
    assert_empty @household.reload.income_sources
    assert_equal 1, @household.historical_income_sources.count
    @household.income_sources.create!(label: "Real job", source_type: "job", cadence: "monthly", amount_cents: 200_000)
    supported.apply(review_id: prepared[:review_id], confirmation: "START OVER")
    assert_equal 1, @household.reload.income_sources.count
    assert_equal 1, @household.household_audit_events.where(event_type: "setup_support.applied").count
  end

  test "request optimistic versions cancellation decline reopen and stale preparation cannot mutate finances" do
    first = request
    staff = SetupHelp::Staff.new(user: @admin)
    triaged = staff.transition(id: first[:id], action: "triage", expected_lock_version: 0)[:request]
    assert_raises(SetupHelp::Stale) { staff.transition(id: first[:id], action: "prepare", expected_lock_version: 0) }
    ready = staff.transition(id: first[:id], action: "prepare", expected_lock_version: triaged[:lock_version])[:request]
    supported = SetupHelp::Restart.new(@household, user: @user, request_id: first[:id])
    @household.income_sources.create!(label: "Concurrent job", source_type: "job", cadence: "monthly", amount_cents: 100_000)
    assert_raises(HouseholdFinance::FinancialRestart::Flow::StaleReview) { supported.apply(review_id: ready[:review_id], confirmation: "START OVER") }
    reopened = @participant.reopen_request(id: first[:id], expected_lock_version: ready[:lock_version])[:request]
    assert_equal "in_review", reopened[:status]
    assert_nil reopened[:review_id]
    assert_equal "canceled", FinancialRestartReview.find(ready[:review_id]).status
    assert_raises(SetupHelp::Error) { supported.preview }
    fresh = staff.transition(id: first[:id], action: "prepare", expected_lock_version: reopened[:lock_version])[:request]
    assert_not_equal ready[:review_id], fresh[:review_id]
    assert_raises(SetupHelp::Stale) { supported.apply(review_id: ready[:review_id], confirmation: "START OVER") }
    assert_raises(SetupHelp::Stale) { supported.cancel(review_id: ready[:review_id]) }
    declined = staff.transition(id: first[:id], action: "decline", expected_lock_version: fresh[:lock_version])[:request]
    assert_equal "declined", declined[:status]
    assert_raises(SetupHelp::Error) { supported.preview }
    assert_equal 0, @household.reload.financial_generation
  end

  test "expired supported review requires fresh staff preparation and live preparer authority" do
    first = request
    ready = SetupHelp::Staff.new(user: @admin).transition(id: first[:id], action: "prepare", expected_lock_version: 0)[:request]
    supported = SetupHelp::Restart.new(@household, user: @user, request_id: first[:id])
    travel 16.minutes do
      assert_equal "expired", @participant.status[:latest_request][:review_state]
      assert_raises(HouseholdFinance::FinancialRestart::Flow::StaleReview) { supported.apply(review_id: ready[:review_id], confirmation: "START OVER") }
    end
    @admin.update!(role: "coach")
    assert_raises(SetupHelp::Denied) { supported.preview }
    assert_raises(SetupHelp::Denied) { supported.apply(review_id: ready[:review_id], confirmation: "START OVER") }
    assert_equal 0, @household.reload.financial_generation
  end

  test "staff and owners cannot reach requests from another account and pagination stays scoped" do
    first = request
    other = create_user("participant")
    other_household = HouseholdFinance::WorkspaceResolver.new(other).household
    stranger = SetupHelp::Restart.new(other_household, user: other, request_id: first[:id])
    assert_raises(ActiveRecord::RecordNotFound) { stranger.preview }
    second = SetupHelp::Participant.new(other_household, user: other).create_request(reason: "other", share_metadata: true, idempotency_key: "other")[:request]
    staff = SetupHelp::Staff.new(user: @admin)
    page = staff.list(cursor: first[:id] > 1 ? first[:id] - 1 : nil, limit: 1)
    assert_equal [ first[:id] ], page[:records].map { |item| item[:id] }
    next_page = staff.list(cursor: page[:next_cursor], limit: 1)
    assert_equal [ second[:id] ], next_page[:records].map { |item| item[:id] }
    assert_raises(SetupHelp::Error) { staff.list(cursor: "1 OR 1=1") }
  end

  test "BOG approved optional cards require support even without savings approval sequence" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_evidence_operations do
        savings_enroll
        participant = SetupHelp::Participant.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership)
        assert participant.status[:self_restart_available]
        terms = debt_approve(debt_stage)
        assert_equal 0, @savings_enrollment.reload.approval_sequence
        assert participant.status[:blockers].any? { |item| item[:code] == "approved_challenge_activity" }
        assert_not participant.status[:self_restart_available]
        assert_equal terms.id, SavingsDebtVersion.find(terms.id).id
      end
    end
  end

  test "BOG support authority requires program and workspace membership with review role and remains private" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_evidence_operations do
        savings_enroll
        savings_plan
        entry = savings_approve(savings_draft(20_000))
        source, document = evidence_source
        evidence_attach(entry, [ evidence_proof(source, amount: 15_000) ])
        card_version = debt_approve(debt_stage)
        participant = SetupHelp::Participant.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership)
        request = participant.create_request(reason: "practice_numbers", share_metadata: true, idempotency_key: "bog")[:request]
        assert_empty SetupHelp::Staff.new(user: @admin).list(cohort_id: @savings_cohort.id)[:records]
        assert_raises(ActiveRecord::RecordNotFound) { SetupHelp::Staff.new(user: @admin).transition(id: request[:id], action: "prepare", expected_lock_version: 0) }
        coach = SetupHelp::Staff.new(user: @savings_owner)
        triaged = coach.transition(id: request[:id], action: "triage", expected_lock_version: 0)[:request]
        assert_raises(SetupHelp::Denied) { coach.transition(id: request[:id], action: "prepare", expected_lock_version: triaged[:lock_version]) }
        @savings_cohort.cohort_memberships.create!(user: @admin, role: "admin")
        workspace_member = CoachWorkspaceMembership.create!(coach_workspace_id: @savings_cohort.coach_workspace_id, user: @admin, role: "viewer")
        staff = SetupHelp::Staff.new(user: @admin)
        projected = staff.list[:records].find { |item| item[:id] == request[:id] }
        assert_equal({ triage: false, prepare: false, decline: false }, projected[:permissions])
        assert_raises(SetupHelp::Denied) { staff.transition(id: request[:id], action: "triage", expected_lock_version: triaged[:lock_version]) }
        assert_raises(SetupHelp::Denied) { staff.transition(id: request[:id], action: "decline", expected_lock_version: triaged[:lock_version]) }
        assert_raises(SetupHelp::Denied) { staff.transition(id: request[:id], action: "prepare", expected_lock_version: triaged[:lock_version]) }
        workspace_member.update!(role: "reviewer")
        assert_equal({ triage: true, prepare: true, decline: true }, staff.list[:records].find { |item| item[:id] == request[:id] }[:permissions])
        ready = staff.transition(id: request[:id], action: "prepare", expected_lock_version: triaged[:lock_version])[:request]
        before = savings_projection
        supported = SetupHelp::Restart.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership, request_id: request[:id])
        assert_raises(ChallengePrivacy::PrivateFinanceAccess::Denied) { ChallengePrivacy::PrivateFinanceAccess.authorize!(@savings_household, user: @admin) }
        supported.apply(review_id: ready[:review_id], confirmation: "START OVER")
        assert_equal before, savings_projection
        assert_equal entry.id, SavingsEntryVersion.find(entry.id).id
        assert_equal card_version.terms, card_version.reload.terms
        assert_equal document.id, FinancialDocumentImport.find(document.id).id
        assert_equal source.id, SourceReviewVersion.find(source.id).id
        assert_equal 15_000, savings_projection[:evidence_supported_cents]
        assert_equal @savings_enrollment.id, SavingsEnrollment.find(@savings_enrollment.id).id
        workspace_member.destroy!
        assert_raises(SetupHelp::Denied) { supported.apply(review_id: ready[:review_id], confirmation: "START OVER") }
      end
    end
  end

  test "new approvals and requester membership changes stale or deny pending pilot self reviews" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_evidence_operations do
        savings_enroll
        flow = SetupHelp::Restart.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership)
        review = flow.preview[:review]
        savings_zero
        assert_raises(SetupHelp::Error) { flow.apply(review_id: review[:id], confirmation: "START OVER") }
        @savings_membership.destroy!
        assert_raises(SetupHelp::Denied) { flow.status(review_id: review[:id]) }
        assert_equal 0, @savings_household.reload.financial_generation
      end
    end
  end

  test "administrators cannot prepare their own supported restart while their testing flow remains available" do
    @user.update!(role: "admin")
    first = request
    staff = SetupHelp::Staff.new(user: @user)
    assert_equal false, staff.list[:records].find { |item| item[:id] == first[:id] }[:permissions][:prepare]
    assert_raises(SetupHelp::Denied) { staff.transition(id: first[:id], action: "prepare", expected_lock_version: 0) }
    assert HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user).status[:available]
  end

  test "withdrawn challenge enrollment denies setup requests preparation confirmation and receipt recovery" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_savings_runtime do
        savings_enroll
        participant = SetupHelp::Participant.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership)
        first = participant.create_request(reason: "practice_numbers", share_metadata: true, idempotency_key: "withdraw")[:request]
        @savings_owner.update!(role: "admin")
        staff = SetupHelp::Staff.new(user: @savings_owner)
        ready = staff.transition(id: first[:id], action: "prepare", expected_lock_version: 0)[:request]
        supported = SetupHelp::Restart.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership, request_id: first[:id])
        supported.apply(review_id: ready[:review_id], confirmation: "START OVER")
        @savings_enrollment.update!(status: "withdrawn")
        assert_raises(SetupHelp::Denied) { participant.status }
        assert_raises(SetupHelp::Denied) { participant.create_request(reason: "other", share_metadata: true, idempotency_key: "withdraw-new") }
        assert_raises(SetupHelp::Denied) { supported.apply(review_id: ready[:review_id], confirmation: "START OVER") }
        assert_empty staff.list(cohort_id: @savings_cohort.id)[:records]
        assert_raises(SetupHelp::Denied) { staff.transition(id: first[:id], action: "prepare", expected_lock_version: ready[:lock_version]) }
        assert_equal 1, @savings_household.reload.financial_generation
      end
    end
  end

  test "replacement challenge membership cannot reuse an enrollment accepted under an earlier membership" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_savings_runtime do
        savings_enroll
        participant = SetupHelp::Participant.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership)
        first = participant.create_request(reason: "other", share_metadata: true, idempotency_key: "stale-enrollment")[:request]
        @savings_membership.destroy!
        replacement = @savings_cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
        rejoined = SetupHelp::Participant.new(@savings_household, user: @savings_user, cohort_membership: replacement)
        assert_raises(SetupHelp::Denied) { rejoined.status }
        assert_raises(SetupHelp::Denied) { rejoined.create_request(reason: "other", share_metadata: true, idempotency_key: "stale-enrollment-new") }
        @savings_owner.update!(role: "admin")
        assert_raises(SetupHelp::Denied) { SetupHelp::Staff.new(user: @savings_owner).transition(id: first[:id], action: "prepare", expected_lock_version: 0) }
        assert_equal 0, @savings_household.reload.financial_generation
      end
    end
  end

  test "disabling a challenge blocks supported confirmation and receipt replay for its existing enrollment" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_savings_runtime do
        savings_enroll
        participant = SetupHelp::Participant.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership)
        first = participant.create_request(reason: "other", share_metadata: true, idempotency_key: "disabled-confirmation")[:request]
        @savings_owner.update!(role: "admin")
        staff = SetupHelp::Staff.new(user: @savings_owner)
        ready = staff.transition(id: first[:id], action: "prepare", expected_lock_version: 0)[:request]
        supported = SetupHelp::Restart.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership, request_id: first[:id])
        @savings_cohort.update!(savings_challenge_enabled: false)
        assert_raises(SetupHelp::Denied) { supported.preview }
        assert_raises(SetupHelp::Denied) { supported.apply(review_id: ready[:review_id], confirmation: "START OVER") }
        assert_empty staff.list(cohort_id: @savings_cohort.id)[:records]
        assert_equal 0, @savings_household.reload.financial_generation
        @savings_cohort.update!(savings_challenge_enabled: true)
        supported.apply(review_id: ready[:review_id], confirmation: "START OVER")
        @savings_cohort.update!(savings_challenge_enabled: false)
        assert_raises(SetupHelp::Denied) { supported.apply(review_id: ready[:review_id], confirmation: "START OVER") }
        assert_equal 1, @savings_household.reload.financial_generation
      end
    end
  end

  test "a disabled and withdrawn enrollment still denies new requests and staff preparation" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_savings_runtime do
        savings_enroll
        participant = SetupHelp::Participant.new(@savings_household, user: @savings_user, cohort_membership: @savings_membership)
        first = participant.create_request(reason: "other", share_metadata: true, idempotency_key: "disabled-withdrawn")[:request]
        @savings_owner.update!(role: "admin")
        @savings_cohort.update!(savings_challenge_enabled: false)
        @savings_enrollment.update!(status: "withdrawn")
        assert_raises(SetupHelp::Denied) { participant.status }
        assert_raises(SetupHelp::Denied) { participant.create_request(reason: "other", share_metadata: true, idempotency_key: "disabled-withdrawn-new") }
        staff = SetupHelp::Staff.new(user: @savings_owner)
        assert_empty staff.list(cohort_id: @savings_cohort.id)[:records]
        assert_raises(SetupHelp::Denied) { staff.transition(id: first[:id], action: "prepare", expected_lock_version: 0) }
        assert_equal 0, @savings_household.reload.financial_generation
      end
    end
  end

  test "an enrollment bound to another household is not treated as never enrolled" do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_savings_runtime do
        savings_enroll
        @savings_household.household_memberships.find_by!(user: @savings_user).destroy!
        replacement = Household.create!(created_by_user: @savings_user, name: "Replacement household")
        replacement.household_memberships.create!(user: @savings_user, role: "owner")
        participant = SetupHelp::Participant.new(replacement, user: @savings_user, cohort_membership: @savings_membership)
        assert_raises(SetupHelp::Denied) { participant.status }
        assert_raises(SetupHelp::Denied) { participant.create_request(reason: "other", share_metadata: true, idempotency_key: "foreign-enrollment-household") }
        assert_equal 0, replacement.reload.financial_generation
        assert_equal @savings_household.id, @savings_enrollment.reload.household_id
      end
    end
  end

  test "ordinary program rejoin retires an old prepared request without retargeting its review and allows fresh request" do
    coach = create_user("coach")
    cohort = Cohort.create!(name: "Ordinary program #{SecureRandom.hex(4)}", status: "active", created_by_user: coach)
    member = cohort.cohort_memberships.create!(user: @user, role: "participant")
    cohort.cohort_memberships.create!(user: @admin, role: "admin")
    CoachWorkspaceMembership.create!(coach_workspace_id: cohort.coach_workspace_id, user: @admin, role: "reviewer")
    participant = SetupHelp::Participant.new(@household, user: @user, cohort_membership: member)
    first = participant.create_request(reason: "wrong_setup", share_metadata: true, idempotency_key: "old-membership")[:request]
    ready = SetupHelp::Staff.new(user: @admin).transition(id: first[:id], action: "prepare", expected_lock_version: 0)[:request]
    old_review = FinancialRestartReview.find(ready[:review_id])
    member.destroy!
    replacement = cohort.cohort_memberships.create!(user: @user, role: "participant")
    rejoined = SetupHelp::Participant.new(@household, user: @user, cohort_membership: replacement)
    fresh = rejoined.create_request(reason: "upload_problem", share_metadata: true, idempotency_key: "new-membership")[:request]
    assert_not_equal first[:id], fresh[:id]
    assert_equal "canceled", SetupSupportRequest.find(first[:id]).status
    assert_equal "canceled", old_review.reload.status
    assert_equal member.id, SetupSupportRequest.find(first[:id]).participant_membership_id
    assert_equal replacement.id, SetupSupportRequest.find(fresh[:id]).participant_membership_id
    assert_equal 1, @household.household_audit_events.where(event_type: "setup_support.retired").count
    assert_equal "participant_membership_changed", @household.household_audit_events.find_by!(event_type: "setup_support.retired").metadata["retirement_reason"]
    assert_equal fresh[:id], rejoined.status[:latest_request][:id]
    stale = SetupHelp::Restart.new(@household, user: @user, cohort_membership: replacement, request_id: first[:id])
    assert_raises(ActiveRecord::RecordNotFound) { stale.apply(review_id: old_review.id, confirmation: "START OVER") }
    assert_equal 0, @household.reload.financial_generation
  end

  private
  def create_user(role)
    id = SecureRandom.hex(6)
    User.create!(clerk_id: "setup-#{id}", email: "setup-#{id}@example.com", role: role, invitation_status: "accepted")
  end
  def request(key = SecureRandom.uuid, reason: "practice_numbers")
    @participant.create_request(reason: reason, share_metadata: true, idempotency_key: key)[:request]
  end
end
