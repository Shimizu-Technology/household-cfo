# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CohortReleaseRuntimeActivatorTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "activator reuses a compatible legacy release and is idempotent" do
    owner = persona_user
    cohort = Cohort.create!(name: "Activate #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    release = CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).tap(&:call)
      .then { cohort.cohort_releases.sole }

    first = CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    replay = CohortReleases::RuntimeActivator.new(cohort: cohort.reload).call!

    assert_equal "activated", first.status
    refute first.sealed
    assert_equal "replayed", replay.status
    assert_equal release, cohort.reload.active_cohort_release
    assert_equal 1, cohort.cohort_release_activation_events.count
  end

  test "activator seals deterministic reconciliation evidence when no matching release exists" do
    owner = persona_user
    cohort = Cohort.create!(name: "Seal activate #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)

    result = CohortReleases::RuntimeActivator.new(cohort: cohort).call!

    assert result.sealed
    assert_equal "system", cohort.reload.active_cohort_release.publication_source
    assert_equal "reconciliation", cohort.active_cohort_release.event_type
    assert cohort.active_cohort_release.integrity_valid?
  end

  test "idempotent replay keeps its original active release after a later equivalent release is sealed" do
    owner = persona_user
    cohort = Cohort.create!(name: "Stable activation #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    original = CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    later = seal_current_bundle(cohort, "later-equivalent-release")

    replay = CohortReleases::RuntimeActivator.new(cohort: cohort.reload).call!

    assert_operator later.release_number, :>, cohort.active_cohort_release.release_number
    assert_equal "replayed", replay.status
    assert_equal original.release_id, replay.release_id
    assert_equal original.release_id, cohort.reload.active_cohort_release_id
    assert_equal 1, cohort.cohort_release_activation_events.count
  end

  test "replay stays pinned after mutable legacy drafts change" do
    owner = persona_user
    cohort = Cohort.create!(name: "Draft drift #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    first = CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    cohort.cohort_experience_configuration.update!(
      draft_config: CohortExperience::Schema::DEFAULT_CONFIG.deep_merge(
        "optional_modules" => { "optionality" => true }
      ),
      last_edited_by_user: owner
    )

    replay = CohortReleases::RuntimeActivator.new(cohort: cohort.reload).call!

    assert_equal "replayed", replay.status
    assert_equal first.release_id, replay.release_id
    assert_equal first.release_id, cohort.reload.active_cohort_release_id
  end

  test "replay follows a valid activation chain after rollout completion" do
    owner = persona_user
    cohort = Cohort.create!(name: "Activation chain #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    participant = persona_user(role: "participant")
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    first = CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    target = seal_current_bundle(cohort, "activation-chain-target")
    rollout = CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.rollout.plan", operation_version: 2,
      input: {
        target_release_id: target.id,
        expected_latest_release_id: target.id,
        expected_roster_digest: CohortRollouts::Contract.roster_digest(cohort),
        waves: [ { name: "Everyone", user_ids: [ participant.id ] } ]
      },
      request_key: "activation-chain-plan"
    ).rollout
    runtime_transition(owner, rollout, "activation-chain-wave")
    runtime_transition(owner, rollout.reload, "activation-chain-complete")

    replay = CohortReleases::RuntimeActivator.new(cohort: cohort.reload).call!

    assert_equal "replayed", replay.status
    assert_equal target.id, replay.release_id
    assert_equal target.id, cohort.reload.active_cohort_release_id
    assert_equal first.release_id, cohort.cohort_release_activation_events.order(:id).first.to_cohort_release_id
  end

  test "batch activation reports a blocked cohort without hiding a successful cohort" do
    owner, blocked, target, participant = legacy_rollout_components
    legacy_plan(owner, blocked, target, participant, "batch-blocked-plan")
    successful = Cohort.create!(name: "Batch success #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)

    results = CohortReleases::RuntimeActivator.call(scope: Cohort.where(id: [ blocked.id, successful.id ]).order(:id))
    by_cohort = results.index_by(&:cohort_id)

    assert_equal "error", by_cohort.fetch(blocked.id).status
    assert_match(/pre-cutover rollout/, by_cohort.fetch(blocked.id).message)
    assert_nil blocked.reload.active_cohort_release_id
    assert_equal "activated", by_cohort.fetch(successful.id).status
    assert_equal by_cohort.fetch(successful.id).release_id, successful.reload.active_cohort_release_id
  end

  test "activator refuses every pre-cutover open state while v1 operations can close it" do
    owner, cohort, target, participant = legacy_rollout_components
    planned = legacy_plan(owner, cohort, target, participant, "legacy-planned")
    assert_raises(CohortReleases::RuntimeActivator::OpenLegacyRollout) do
      CohortReleases::RuntimeActivator.new(cohort: cohort).call!
    end
    legacy_transition(owner, planned, "cohort.rollout.cancel", transition_input(planned), "legacy-cancel")
    assert_equal "activated", CohortReleases::RuntimeActivator.new(cohort: cohort.reload).call!.status

    next_target = seal_current_bundle(cohort, "legacy-next-target")
    active = legacy_plan(owner, cohort, next_target, participant, "legacy-active-plan")
    legacy_transition(
      owner,
      active,
      "cohort.rollout.advance",
      transition_input(active).merge("readiness_digest" => CohortRollouts::Contract.readiness_digest_for_advance(active)),
      "legacy-activate"
    )
    assert_raises(CohortReleases::RuntimeActivator::OpenLegacyRollout) do
      CohortReleases::RuntimeActivator.new(cohort: cohort.reload).call!
    end
    legacy_transition(owner, active.reload, "cohort.rollout.pause", transition_input(active), "legacy-pause")
    legacy_transition(owner, active.reload, "cohort.rollout.resume", transition_input(active), "legacy-resume")
    legacy_transition(
      owner,
      active.reload,
      "cohort.rollout.rollback",
      transition_input(active).merge("rollback_release_id" => target.id),
      "legacy-rollback"
    )
    assert_equal "replayed", CohortReleases::RuntimeActivator.new(cohort: cohort.reload).call!.status
  end

  private

  def legacy_rollout_components
    owner = persona_user
    cohort = Cohort.create!(name: "Legacy rollout #{SecureRandom.hex(4)}", status: "active", created_by_user: owner)
    participant = persona_user(role: "participant")
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    first = seal_current_bundle(cohort, "legacy-first")
    target = seal_current_bundle(cohort, "legacy-target")
    [ owner, cohort, target, participant ]
  end

  def seal_current_bundle(cohort, key)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
    CohortReleases::Sealer.new(cohort: cohort, actor: nil, publication_source: "system").call!(
      request_key: key, expected_bundle_digest: candidate.bundle_digest
    )
  end

  def legacy_plan(owner, cohort, target, participant, key)
    CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.rollout.plan", operation_version: 1,
      input: {
        target_release_id: target.id,
        expected_latest_release_id: target.id,
        expected_roster_digest: CohortRollouts::Contract.roster_digest(cohort),
        waves: [ { name: "Everyone", user_ids: [ participant.id ] } ]
      },
      request_key: key
    ).rollout
  end

  def legacy_transition(owner, rollout, operation, input, key)
    CoachOperations::Runner.new(cohort: rollout.cohort, actor: owner).call!(
      operation_key: operation, operation_version: 1, input: input, request_key: key
    )
  end

  def runtime_transition(owner, rollout, key)
    CoachOperations::Runner.new(cohort: rollout.cohort, actor: owner).call!(
      operation_key: "cohort.rollout.advance",
      operation_version: 2,
      input: transition_input(rollout).merge(
        readiness_digest: CohortRollouts::Contract.readiness_digest_for_advance(rollout)
      ),
      request_key: key
    )
  end

  def transition_input(rollout)
    rollout.reload
    {
      rollout_id: rollout.id,
      expected_status: rollout.status,
      expected_current_wave_position: rollout.current_wave_position,
      expected_latest_transition_id: rollout.transitions.reorder(id: :desc).pick(:id)
    }
  end
end
