module SavingsChallengeTestSupport
  def setup_savings_context
    @savings_user = User.create!(clerk_id: "clerk_savings_#{SecureRandom.hex(8)}", email: "savings-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @savings_household = HouseholdFinance::WorkspaceResolver.new(@savings_user).household
    @savings_owner = User.create!(clerk_id: "clerk_savings_coach_#{SecureRandom.hex(8)}", email: "savings-coach-#{SecureRandom.hex(8)}@example.com", role: "coach", invitation_status: "accepted")
    @savings_cohort = Cohort.create!(name: "Savings #{SecureRandom.hex(8)}", status: "enrolling", created_by_user: @savings_owner,
      starts_on: Date.new(2026, 11, 1), savings_challenge_enabled: true, savings_challenge_release_hold: false)
    @savings_membership = CohortMembership.create!(cohort: @savings_cohort, user: @savings_user, role: "participant")
  end

  # A system-sealed neutral fixture exercises the actual release resolver and
  # compatibility checks. The real activator records the atomic pointer evidence.
  def with_savings_runtime
    unless @savings_release
      configuration = @savings_cohort.cohort_experience_configuration
      configuration.update!(draft_config: CohortExperience::Schema::PILOT_SAVINGS_CONFIG, last_edited_by_user: @savings_owner)
      publisher = CohortExperience::Publisher.new(configuration: configuration, actor: @savings_owner)
      digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
      publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision,
        expected_current_version_id: configuration.current_published_version_id)
      @savings_release = CohortReleases::Sealer.new(cohort: @savings_cohort, actor: nil, publication_source: "system").call!(request_key: "synthetic-savings-runtime")
      CohortReleases::RuntimeActivator.new(cohort: @savings_cohort).call!
    end
    yield
  end

  def savings_offer_digest(user: @savings_user)
    membership = @savings_cohort.cohort_memberships.find_by!(user_id: user.id, role: "participant")
    SavingsChallenge::EnrollmentOffer.call(cohort: @savings_cohort.reload, user: user, membership: membership).fetch(:acceptance_digest)
  end

  def savings_run(key, input, token: SecureRandom.uuid, user: @savings_user, household: @savings_household)
    HouseholdFinance::Operations::Runner.new(household, user: user).run(operation_key: "savings.#{key}",
      input: input.merge(cohort_id: @savings_cohort.id), idempotency_key: token)
  end

  def savings_enroll(token: SecureRandom.uuid, late: true)
    @savings_enrollment = savings_run("enrollment.accept", { participation_accepted: true, policy_version: "1", late_start_accepted: late, expected_acceptance_digest: savings_offer_digest }, token: token).subject
  end

  def savings_plan(target = 50_000)
    @savings_enrollment.reload
    draft = savings_run("plan.stage", { target_cents: target, expected_plan_version_id: @savings_enrollment.current_accepted_plan_version_id,
      reason: @savings_enrollment.current_accepted_plan_version_id ? "Affordable plan revision" : "" }).subject
    savings_run("plan.approve", { draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version,
      expected_plan_version_id: draft.base_plan_version_id }).subject
  end

  def savings_draft(amount, entry: nil, on: @savings_enrollment.local_today, funding: "new_money_reserved")
    entry&.reload
    savings_run("entry.stage", { signed_cents: amount, effective_on: on.iso8601, funding_source: funding,
      expected_version_id: entry&.current_approved_version_id, entry_id: entry&.id,
      expected_entry_lock_version: entry&.lock_version || 0, reason: entry&.current_approved_version_id ? "Corrected the reported reservation" : "" }).subject
  end

  def savings_approve(draft, token: SecureRandom.uuid)
    savings_run("entry.approve", { draft_id: draft.id, accepted: true, expected_draft_lock_version: draft.lock_version,
      expected_version_id: draft.base_version_id, expected_entry_lock_version: draft.base_entry_lock_version }, token: token).subject
  end

  def savings_projection(**options)
    SavingsChallenge::Projection.new(@savings_enrollment.reload, **options).call
  end

  def savings_zero(on: @savings_enrollment.local_today)
    savings_run("zero.attest", { cutoff_on: on.iso8601, known_zero: true, expected_enrollment_lock_version: @savings_enrollment.reload.lock_version }).subject
  end
end
