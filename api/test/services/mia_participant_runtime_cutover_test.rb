# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaParticipantRuntimeCutoverTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ActiveJob::TestHelper

  setup do
    CohortReleases::RuntimeIntegrityCache.clear!
  end

  test "one immutable release pins persona approved content and participant tools for each exposed wave" do
    owner, cohort, baseline, target, participants = runtime_components
    cohort.update!(active_cohort_release: baseline)
    rollout = plan_runtime_rollout(owner, cohort, target, participants)

    advance_runtime_rollout(owner, rollout, "runtime-wave-1")

    first = Mia::ParticipantRuntimeResolver.new(
      user: participants.first,
      cohort_membership: membership_for(cohort, participants.first)
    ).call
    second = Mia::ParticipantRuntimeResolver.new(
      user: participants.second,
      cohort_membership: membership_for(cohort, participants.second)
    ).call

    assert_equal target.id, first.release_id
    assert_equal "Coach Target", first.persona.name
    assert first.capabilities.fetch(:modules).find { |item| item.fetch(:id) == "optionality" }.fetch(:enabled)
    assert_equal [ "Target coaching rule" ], Mia::ApprovedContentRetriever.new(
      persona: first.persona, query: "target coaching rule"
    ).call.map { |entry| entry.fetch(:item_version).title }

    assert_equal baseline.id, second.release_id
    assert_equal Mia::Persona::NEUTRAL_ID, second.persona.id
    refute second.capabilities.fetch(:modules).find { |item| item.fetch(:id) == "optionality" }.fetch(:enabled)
    assert_equal "cohort_release:#{target.id}", first.continuity_id
    assert_equal "cohort_release:#{baseline.id}", second.continuity_id
  end

  test "completion promotes the target and rollback restores every exposed participant to the captured baseline" do
    owner, cohort, baseline, target, participants = runtime_components
    cohort.update!(active_cohort_release: baseline)
    rollout = plan_runtime_rollout(owner, cohort, target, participants)

    advance_runtime_rollout(owner, rollout, "complete-wave-1")
    advance_runtime_rollout(owner, rollout.reload, "complete-wave-2")
    completion = advance_runtime_rollout(owner, rollout.reload, "complete-rollout")

    assert_equal "completed", completion.transition.event_type
    assert completion.transition.participant_runtime_changed
    assert_equal target, cohort.reload.active_cohort_release
    assert_equal 1, cohort.cohort_release_activation_events.where(event_type: "rollout_completed").count
    participants.each do |participant|
      runtime = Mia::ParticipantRuntimeResolver.new(
        user: participant,
        cohort_membership: membership_for(cohort, participant)
      ).call
      assert_equal target.id, runtime.release_id
    end

    third = seal_current_bundle(cohort, "runtime-target-3")
    second_rollout = plan_runtime_rollout(owner, cohort, third, participants, key: "runtime-plan-rollback")
    advance_runtime_rollout(owner, second_rollout, "rollback-wave-1")
    rolled_back = run_rollout(
      owner,
      second_rollout.reload,
      "cohort.rollout.rollback",
      transition_input(second_rollout).merge("rollback_release_id" => target.id),
      "runtime-rollback"
    )

    assert_equal "rolled_back", rolled_back.transition.event_type
    assert_equal participants.first.id,
      second_rollout.cohort_release_exposures.where(event_type: "rollback").sole.user_id
    participants.each do |participant|
      runtime = Mia::ParticipantRuntimeResolver.new(
        user: participant,
        cohort_membership: membership_for(cohort, participant)
      ).call
      assert_equal target.id, runtime.release_id
    end
  end

  test "membership epochs prevent stale exposure reuse after removal and re-enrollment" do
    owner, cohort, baseline, target, participants = runtime_components
    cohort.update!(active_cohort_release: baseline)
    rollout = plan_runtime_rollout(owner, cohort, target, participants)
    advance_runtime_rollout(owner, rollout, "epoch-wave")
    participant = participants.first
    original = membership_for(cohort, participant)

    original.destroy!
    replacement = cohort.cohort_memberships.create!(user: participant, role: "participant")
    runtime = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: replacement).call

    assert_equal baseline.id, runtime.release_id
    assert_equal "cohort_active_release", runtime.source
    assert CohortReleaseExposure.where(cohort_membership_id: original.id).exists?
  end

  test "a rollout cannot expose a replacement membership created after planning" do
    owner, cohort, baseline, target, participants = runtime_components
    cohort.update!(active_cohort_release: baseline)
    rollout = plan_runtime_rollout(owner, cohort, target, participants)
    participant = participants.first
    membership_for(cohort, participant).destroy!
    cohort.cohort_memberships.create!(user: participant, role: "participant")

    error = assert_raises(CohortRollouts::StateMachine::Ineligible) do
      advance_runtime_rollout(owner, rollout, "replacement-membership-wave")
    end

    assert_includes error.blockers,
      "A participant enrollment changed after this rollout was planned. Roll back this rollout and create a new plan."
    assert_empty rollout.cohort_release_exposures
    assert_equal "planned", rollout.reload.status
  end

  test "version one cannot mutate a release-runtime rollout" do
    owner, cohort, baseline, target, participants = runtime_components
    cohort.update!(active_cohort_release: baseline)
    rollout = plan_runtime_rollout(owner, cohort, target, participants)
    transition_count = rollout.transitions.count
    execution_count = cohort.coach_operation_executions.count

    error = assert_raises(CoachOperations::Runner::InvalidRequest) do
      CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
        operation_key: "cohort.rollout.advance",
        operation_version: 1,
        input: transition_input(rollout).merge(
          "readiness_digest" => CohortRollouts::Contract.readiness_digest_for_advance(rollout)
        ),
        request_key: "runtime-version-pair-advance"
      )
    end

    assert_match(/operation_version must be 2/, error.message)
    assert_equal "planned", rollout.reload.status
    assert_equal transition_count, rollout.transitions.count
    assert_equal execution_count, cohort.coach_operation_executions.count
  end

  test "changed membership epochs block forward progress but rollback closes the rollout and replacement inherits baseline" do
    owner, cohort, baseline, target, participants = runtime_components
    cohort.update!(active_cohort_release: baseline)
    rollout = plan_runtime_rollout(owner, cohort, target, participants)
    advance_runtime_rollout(owner, rollout, "changed-epoch-wave-one")
    participant = participants.first
    membership_for(cohort, participant).destroy!
    replacement = cohort.cohort_memberships.create!(user: participant, role: "participant")

    studio = CohortRollouts::StudioSerializer.new(cohort: cohort, actor: owner).call.fetch(:open_rollout)
    first_wave = studio.fetch(:waves).find { |wave| wave.fetch(:position) == 1 }
    refute first_wave.fetch(:participants).sole.fetch(:exposed)
    assert_equal 0, first_wave.fetch(:exposed_count)
    refute first_wave.fetch(:exposure_complete)
    refute studio.dig(:permissions, :advance)
    assert_includes studio.dig(:permissions, :advance_blockers),
      "A participant enrollment changed after this rollout was planned. Roll back this rollout and create a new plan."

    error = assert_raises(CohortRollouts::StateMachine::Ineligible) do
      advance_runtime_rollout(owner, rollout, "changed-epoch-wave-two")
    end
    assert_includes error.blockers,
      "A participant enrollment changed after this rollout was planned. Roll back this rollout and create a new plan."
    assert_equal 1, rollout.reload.current_wave_position

    result = run_rollout(
      owner,
      rollout,
      "cohort.rollout.rollback",
      transition_input(rollout).merge("rollback_release_id" => baseline.id),
      "changed-epoch-rollback"
    )

    assert_equal "rolled_back", result.transition.event_type
    assert_equal "rolled_back", rollout.reload.status
    assert_empty result.transition.cohort_release_exposures
    runtime = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: replacement).call
    assert_equal baseline.id, runtime.release_id
    assert_equal "cohort_active_release", runtime.source
  end

  test "rollback closes an active rollout when its exposed membership was removed without replacement" do
    owner, cohort, baseline, target, participants = runtime_components
    cohort.update!(active_cohort_release: baseline)
    rollout = plan_runtime_rollout(owner, cohort, target, participants)
    advance_runtime_rollout(owner, rollout, "removed-epoch-wave-one")
    membership_for(cohort, participants.first).destroy!

    result = run_rollout(
      owner,
      rollout,
      "cohort.rollout.rollback",
      transition_input(rollout).merge("rollback_release_id" => baseline.id),
      "removed-epoch-rollback"
    )

    assert_equal "rolled_back", result.transition.event_type
    assert_equal "rolled_back", rollout.reload.status
    assert_empty result.transition.cohort_release_exposures
  end

  test "standalone and multi-cohort selection are deterministic and never merge releases" do
    participant = persona_user(role: "participant")
    standalone = Mia::ParticipantRuntimeResolver.new(user: participant).call
    assert_equal "standalone_default", standalone.source
    assert_nil standalone.release_id

    owner = persona_user
    first = Cohort.create!(name: "First #{SecureRandom.hex(4)}", status: "active", starts_on: Date.new(2026, 1, 1), created_by_user: owner)
    second = Cohort.create!(name: "Second #{SecureRandom.hex(4)}", status: "active", starts_on: Date.new(2027, 1, 1), created_by_user: owner)
    first_membership = first.cohort_memberships.create!(user: participant, role: "participant")
    second_membership = second.cohort_memberships.create!(user: participant, role: "participant")
    first_release = seal_current_bundle(first, "first-runtime")
    second_release = seal_current_bundle(second, "second-runtime")
    first.update!(active_cohort_release: first_release)
    second.update!(active_cohort_release: second_release)

    assert_equal second_membership, Mia::EffectiveCohortResolver.new(user: participant, role: "participant").call
    selected = Mia::EffectiveCohortResolver.new(
      user: participant, role: "participant", requested_cohort_id: first.id
    ).call
    assert_equal first_membership, selected
    runtime = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: selected).call
    assert_equal first_release.id, runtime.release_id
    refute_equal second_release.id, runtime.release_id
  end

  test "assistant and participant turns are attributed and transcripts stop at a release boundary" do
    owner, cohort, baseline, target, participants = runtime_components
    participant = participants.first
    membership = membership_for(cohort, participant)
    cohort.update!(active_cohort_release: baseline)
    baseline_runtime = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: membership).call
    household = HouseholdFinance::WorkspaceResolver.new(participant).household
    session = household.chat_sessions.create!(user: participant, title: "Ask Mia")
    session.chat_messages.create!(role: "user", content: "Old question", cohort: cohort, cohort_release: baseline)
    Mia::AssistantMessageWriter.new(
      session: session, persona: baseline_runtime.persona, participant_runtime: baseline_runtime
    ).create!(content: "Old answer")

    cohort.update!(active_cohort_release: target)
    target_runtime = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: membership).call
    session.chat_messages.create!(role: "user", content: "New question", cohort: cohort, cohort_release: target)
    assistant = Mia::AssistantMessageWriter.new(
      session: session, persona: target_runtime.persona, participant_runtime: target_runtime
    ).create!(content: "New answer")
    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(
      session,
      persona_version_id: target_runtime.persona.version_id,
      cohort_release_id: target.id
    ).call

    assert_equal target.id, assistant.cohort_release_id
    assert_equal [ "New question", "New answer" ], transcript.pluck(:content)
  end

  test "a corrupt selected release falls back to neutral persona and safe capabilities as one bundle" do
    _owner, cohort, _baseline, target, participants = runtime_components
    participant = participants.first
    membership = membership_for(cohort, participant)
    cohort.update!(active_cohort_release: target)
    release_class = CohortRelease
    original_integrity_report = release_class.instance_method(:integrity_report)
    release_class.define_method(:integrity_report) do
      if id == target.id
        { valid: false, runtime_compatible: false, errors: [ "simulated corruption" ] }
      else
        original_integrity_report.bind_call(self)
      end
    end

    runtime = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: membership).call

    assert_equal "safe_fallback", runtime.source
    assert_nil runtime.release_id
    assert_equal Mia::Persona::NEUTRAL_ID, runtime.persona.id
    assert_equal "safe_default", runtime.capabilities.fetch(:source)
    assert runtime.capabilities.fetch(:modules).reject { |item| item.fetch(:core) }.none? { |item| item.fetch(:enabled) }
  ensure
    release_class&.define_method(:integrity_report, original_integrity_report) if original_integrity_report
  end

  test "legacy and safe fallback runtime context stays isolated between cohort memberships" do
    owner = persona_user
    participant = persona_user(role: "participant")
    first = Cohort.create!(name: "Legacy first #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    second = Cohort.create!(name: "Legacy second #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    first_membership = first.cohort_memberships.create!(user: participant, role: "participant")
    second_membership = second.cohort_memberships.create!(user: participant, role: "participant")
    first_runtime = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: first_membership).call
    second_runtime = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: second_membership).call

    refute_equal first_runtime.continuity_id, second_runtime.continuity_id
    household = HouseholdFinance::WorkspaceResolver.new(participant).household
    session = household.chat_sessions.create!(user: participant, title: "Ask Mia")
    session.chat_messages.create!(role: "user", content: "First cohort context", cohort: first)
    session.chat_messages.create!(role: "user", content: "Second cohort context", cohort: second)
    transcript = HouseholdFinance::ConversationTranscriptBuilder.new(
      session,
      cohort_id: first.id,
      cohort_release_id: nil
    ).call
    assert_equal [ "First cohort context" ], transcript.pluck(:content)

    first_release = seal_current_bundle(first, "safe-first")
    second_release = seal_current_bundle(second, "safe-second")
    first.update!(active_cohort_release: first_release)
    second.update!(active_cohort_release: second_release)
    release_class = CohortRelease
    original_integrity_report = release_class.instance_method(:integrity_report)
    corrupt_ids = [ first_release.id, second_release.id ]
    release_class.define_method(:integrity_report) do
      if id.in?(corrupt_ids)
        { valid: false, runtime_compatible: false, errors: [ "simulated corruption" ] }
      else
        original_integrity_report.bind_call(self)
      end
    end
    first_safe = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: first_membership).call
    second_safe = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: second_membership).call

    assert_equal "safe_fallback", first_safe.source
    assert_equal "safe_fallback", second_safe.source
    refute_equal first_safe.continuity_id, second_safe.continuity_id
    first_message = Mia::AssistantMessageWriter.new(
      session: session, persona: first_safe.persona, participant_runtime: first_safe
    ).create!(content: "First safe answer")
    assert_equal first.id, first_message.cohort_id
    assert_nil first_message.cohort_release_id
  ensure
    release_class&.define_method(:integrity_report, original_integrity_report) if original_integrity_report
  end

  test "later rollback exposure wins even when its wall clock moves backward" do
    owner, cohort, baseline, target, participants = runtime_components
    cohort.update!(active_cohort_release: baseline)
    rollout = plan_runtime_rollout(owner, cohort, target, participants)
    travel_to Time.zone.parse("2026-10-03 12:00:00") do
      advance_runtime_rollout(owner, rollout, "clock-forward-wave")
    end
    travel_to Time.zone.parse("2026-10-03 11:00:00") do
      run_rollout(
        owner,
        rollout.reload,
        "cohort.rollout.rollback",
        transition_input(rollout).merge("rollback_release_id" => baseline.id),
        "clock-backward-rollback"
      )
    end

    runtime = Mia::ParticipantRuntimeResolver.new(
      user: participants.first,
      cohort_membership: membership_for(cohort, participants.first)
    ).call
    studio = CohortRollouts::StudioSerializer.new(cohort: cohort, actor: owner).call
    participant_payload = studio.dig(:current_roster, :participants).find do |item|
      item.fetch(:user_id) == participants.first.id
    end

    assert_equal baseline.id, runtime.release_id
    assert_equal baseline.id, participant_payload.dig(:effective_release, :id)
  end

  test "immutable release integrity verdicts are reused across resolver instances" do
    _owner, cohort, _baseline, target, participants = runtime_components
    participant = participants.first
    membership = membership_for(cohort, participant)
    cohort.update!(active_cohort_release: target)
    release_class = CohortRelease
    original_integrity_report = release_class.instance_method(:integrity_report)
    calls = 0
    release_class.define_method(:integrity_report) do
      calls += 1 if id == target.id
      original_integrity_report.bind_call(self)
    end

    first = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: membership).call
    second = Mia::ParticipantRuntimeResolver.new(user: participant, cohort_membership: membership).call

    assert_equal target.id, first.release_id
    assert_equal target.id, second.release_id
    assert_equal 1, calls
  ensure
    release_class&.define_method(:integrity_report, original_integrity_report) if original_integrity_report
    CohortReleases::RuntimeIntegrityCache.clear!
  end

  private

  def runtime_components
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Runtime rollout #{SecureRandom.hex(4)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )
    participants = 2.times.map do |index|
      participant = persona_user(role: "participant", email: "runtime-#{index}-#{SecureRandom.hex(4)}@example.com")
      cohort.cohort_memberships.create!(user: participant, role: "participant")
      participant
    end
    baseline = seal_current_bundle(cohort, "runtime-baseline")

    item = approved_content_item(owner: owner, title: "Target coaching rule", content: "Use the target coaching rule.")
    pack = published_content_pack(owner: owner, items: [ item ])
    persona = create_persona(
      creator: owner,
      name: "Target persona",
      config: persona_configuration(assistant_name: "Coach Target", coach_name: "Coach Owner"),
      workspace: workspace
    )
    persona.replace_draft_content_pack_versions!([ pack.current_published_version ], actor: owner)
    publish_persona(persona, actor: owner)
    CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: owner)
    configuration = cohort.cohort_experience_configuration
    configuration.update!(
      draft_config: CohortExperience::Schema::DEFAULT_CONFIG.deep_merge("optional_modules" => { "optionality" => true }),
      last_edited_by_user: owner
    )
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: configuration.draft_revision,
      expected_current_version_id: nil
    )
    target = seal_current_bundle(cohort, "runtime-target")
    [ owner, cohort, baseline, target, participants ]
  end

  def seal_current_bundle(cohort, key)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
    CohortReleases::Sealer.new(cohort: cohort, actor: nil, publication_source: "system").call!(
      request_key: key,
      expected_bundle_digest: candidate.bundle_digest
    )
  end

  def membership_for(cohort, participant)
    cohort.cohort_memberships.find_by!(user: participant, role: "participant")
  end

  def plan_runtime_rollout(owner, cohort, target, participants, key: "runtime-plan")
    result = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.rollout.plan",
      operation_version: 2,
      input: {
        target_release_id: target.id,
        expected_latest_release_id: target.id,
        expected_roster_digest: CohortRollouts::Contract.roster_digest(cohort),
        waves: participants.each_with_index.map do |participant, index|
          { name: "Wave #{index + 1}", user_ids: [ participant.id ] }
        end
      },
      request_key: key
    )
    result.rollout
  end

  def advance_runtime_rollout(owner, rollout, key)
    run_rollout(
      owner,
      rollout.reload,
      "cohort.rollout.advance",
      transition_input(rollout).merge(
        "readiness_digest" => CohortRollouts::Contract.readiness_digest_for_advance(rollout)
      ),
      key
    )
  end

  def run_rollout(owner, rollout, operation, input, key)
    CoachOperations::Runner.new(cohort: rollout.cohort, actor: owner).call!(
      operation_key: operation,
      operation_version: 2,
      input: input,
      request_key: key
    )
  end

  def transition_input(rollout)
    rollout.reload
    {
      "rollout_id" => rollout.id,
      "expected_status" => rollout.status,
      "expected_current_wave_position" => rollout.current_wave_position,
      "expected_latest_transition_id" => rollout.transitions.reorder(id: :desc).pick(:id)
    }
  end
end
