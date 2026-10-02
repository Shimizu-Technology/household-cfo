# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CoachOperationsReleaseTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "registry exposes typed coach operations without adding participant tools" do
    assert_equal %w[cohort.release.restore cohort.release.seal], CoachOperations::Registry.operations.keys.sort
    assert_equal 1, CoachOperations::Registry.fetch("cohort.release.seal", version: 1)::VERSION

    participant_keys = HouseholdFinance::Operations::Registry.operations.keys
    refute_includes participant_keys, "cohort.release.seal"
    refute_includes participant_keys, "cohort.release.restore"
  end

  test "runner seals exact reviewed evidence and replays the same request" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    input = seal_input(cohort, assignment, persona_version, experience_version)

    first = run_seal(cohort, owner, input, request_key: "coach-release-1")
    replay = run_seal(cohort, owner, input, request_key: "coach-release-1")

    assert_equal false, first.replayed
    assert_equal true, replay.replayed
    assert_equal first.execution, replay.execution
    assert_equal first.release, replay.release
    assert_equal 1, cohort.coach_operation_executions.count
    assert_equal "owner", first.execution.actor_role_snapshot
    assert_equal false, first.execution.after_snapshot.fetch("participant_runtime_changed")
    assert_equal first.release.id, first.execution.after_snapshot.fetch("latest_release_id")
    assert_nil first.execution.predicted_after_snapshot.fetch("latest_release_id")
    assert first.execution.predicted_after_snapshot.fetch("latest_release_id_pending")
  end

  test "different request keys cannot seal the same latest bundle twice" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    input = seal_input(cohort, assignment, persona_version, experience_version)
    run_seal(cohort, owner, input, request_key: "first-key")

    error = assert_raises(CohortReleases::Sealer::AlreadyRecorded) do
      run_seal(cohort, owner, input, request_key: "different-key")
    end
    assert_includes error.message, "already sealed"
    assert_equal 1, cohort.cohort_releases.count
    assert_equal 1, cohort.coach_operation_executions.count
  end

  test "idempotency key conflicts on canonical input changes" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    input = seal_input(cohort, assignment, persona_version, experience_version)
    run_seal(cohort, owner, input, request_key: "fixed-key")

    assert_raises(CoachOperations::Runner::IdempotencyConflict) do
      run_seal(cohort, owner, input.merge("expected_tool_registry_version" => 2), request_key: "fixed-key")
    end
  end

  test "operation input is canonical and rejects missing or unknown review tokens" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    input = seal_input(cohort, assignment, persona_version, experience_version)

    assert_raises(CoachOperations::Runner::InvalidRequest) do
      run_seal(cohort, owner, input.except("expected_assignment_id"), request_key: "missing-input")
    end
    assert_raises(CoachOperations::Runner::InvalidRequest) do
      run_seal(cohort, owner, input.merge("unreviewed" => true), request_key: "unknown-input")
    end
    assert_empty cohort.cohort_releases
  end

  test "review token IDs reject numeric coercion and nullable component IDs remain explicit" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    input = seal_input(cohort, assignment, persona_version, experience_version)

    [ 1.9, "0x#{assignment.id.to_s(16)}", "#{assignment.id}_0", "0#{assignment.id}" ].each_with_index do |value, index|
      assert_raises(CoachOperations::Runner::InvalidRequest) do
        run_seal(
          cohort,
          owner,
          input.merge("expected_assignment_id" => value),
          request_key: "invalid-id-#{index}"
        )
      end
    end

    operation = CoachOperations::CohortReleaseSeal.new(
      cohort: cohort,
      actor: owner,
      actor_role_snapshot: "owner"
    )
    normalized = operation.normalized_input(input.merge(
      "expected_assignment_id" => nil,
      "expected_persona_version_id" => nil,
      "expected_experience_version_id" => nil
    ))
    assert_nil normalized.fetch("expected_assignment_id")
    assert_nil normalized.fetch("expected_persona_version_id")
    assert_nil normalized.fetch("expected_experience_version_id")

    assert_raises(CohortReleases::Sealer::Stale) do
      run_seal(cohort, owner, normalized, request_key: "nullable-is-not-a-wildcard")
    end
    assert_empty cohort.cohort_releases

    restore = CoachOperations::CohortReleaseRestore.new(
      cohort: cohort,
      actor: owner,
      actor_role_snapshot: "owner"
    ).normalized_input(
      "expected_latest_release_id" => 1,
      "source_bundle_digest" => "a" * 64,
      "source_experience_version_id" => nil,
      "source_persona_version_id" => nil,
      "source_release_id" => 1
    )
    assert_nil restore.fetch("source_persona_version_id")
    assert_nil restore.fetch("source_experience_version_id")
  end

  test "nullable component IDs reach incomplete release governance" do
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Incomplete operation #{SecureRandom.hex(4)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
    input = {
      "expected_assignment_id" => nil,
      "expected_bundle_digest" => candidate.bundle_digest,
      "expected_experience_version_id" => nil,
      "expected_latest_release_id" => nil,
      "expected_persona_version_id" => nil,
      "expected_tool_registry_digest" => CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
      "expected_tool_registry_version" => CohortReleases::Contract::TOOL_REGISTRY_VERSION
    }

    error = assert_raises(CohortReleases::Sealer::Incomplete) do
      run_seal(cohort, owner, input, request_key: "incomplete-nullable-components")
    end
    assert error.blockers.any? { |blocker| blocker.include?("persona") }
    assert error.blockers.any? { |blocker| blocker.include?("participant tools") }
    assert_empty cohort.cohort_releases
  end

  test "stale latest record and registry evidence fail closed" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    input = seal_input(cohort, assignment, persona_version, experience_version)

    assert_raises(CohortReleases::Sealer::Stale) do
      run_seal(cohort, owner, input.merge("expected_latest_release_id" => 999_999), request_key: "stale-latest")
    end
    assert_raises(CohortReleases::Sealer::Stale) do
      run_seal(
        cohort,
        owner,
        input.merge("expected_tool_registry_digest" => "f" * 64),
        request_key: "stale-registry"
      )
    end
    assert_empty cohort.cohort_releases
    assert_empty cohort.coach_operation_executions
  end

  test "revoked release authority is checked before execution and replay" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    input = seal_input(cohort, assignment, persona_version, experience_version)
    result = run_seal(cohort, owner, input, request_key: "authorized-once")
    owner_membership = cohort.coach_workspace.coach_workspace_memberships.find_by!(user: owner)
    owner_membership.update!(role: "viewer")

    assert_raises(CoachOperations::Runner::NotAuthorized) do
      run_seal(cohort, owner, input, request_key: "authorized-once")
    end
    assert_equal result.execution, cohort.coach_operation_executions.sole
  end

  test "operation evidence is immutable and validates every digest even when payloads match" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    result = run_seal(
      cohort,
      owner,
      seal_input(cohort, assignment, persona_version, experience_version),
      request_key: "immutable-operation"
    )
    execution = result.execution

    refute execution.update(request_key: "changed")
    assert_includes execution.errors[:base], "coach operation executions are immutable"
    refute execution.destroy
    assert_raises(ActiveRecord::StatementInvalid) do
      CoachOperationExecution.transaction(requires_new: true) do
        execution.update_column(:after_snapshot_digest, "0" * 64)
      end
    end

    forged = execution.dup
    identical = { "same" => true }
    forged.normalized_input = identical
    forged.before_snapshot = identical
    forged.predicted_after_snapshot = identical
    forged.after_snapshot = identical
    digest = CoachOperations::Contract.digest(identical)
    forged.normalized_input_digest = digest
    forged.before_snapshot_digest = digest
    forged.predicted_after_snapshot_digest = "0" * 64
    forged.after_snapshot_digest = digest
    refute forged.valid?
    assert_includes forged.errors[:predicted_after_snapshot_digest], "does not match the canonical evidence"

    forged = execution.dup
    forged.before_snapshot = forged.before_snapshot.merge("release_count" => 99)
    forged.before_snapshot_digest = CoachOperations::Contract.digest(forged.before_snapshot)
    forged.predicted_after_snapshot = forged.predicted_after_snapshot.merge("latest_release_number" => 99)
    forged.predicted_after_snapshot_digest = CoachOperations::Contract.digest(forged.predicted_after_snapshot)
    refute forged.valid?
    assert_includes forged.errors[:before_snapshot], "does not match the prior release state"
    assert_includes forged.errors[:predicted_after_snapshot], "does not match the linked release"
  end

  test "history never reports an unsealed persona version as runtime compatible" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    result = run_seal(
      cohort,
      owner,
      seal_input(cohort, assignment, persona_version, experience_version),
      request_key: "runtime-compatibility"
    )
    persona_version.update_column(:sealed_at, nil)

    assert_equal false, result.release.reload.integrity_report.fetch(:runtime_compatible)
    payload = CohortReleases::StudioSerializer.new(cohort: cohort, actor: owner).call
    assert_equal false, payload.fetch(:releases).sole.fetch(:runtime_compatible)
    assert_includes payload.fetch(:releases).sole.fetch(:restore_blockers),
      "The selected release is not compatible with the current runtime."
  end

  test "history work stays bounded as release rows reuse governed evidence" do
    owner, cohort, = governed_components
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: false).call
    100.times do |index|
      CohortReleases::Sealer.new(cohort: cohort, actor: nil, publication_source: "system").call!(
        request_key: "bounded-history-#{index}",
        expected_bundle_digest: candidate.bundle_digest
      )
    end

    evidence_calls = 0
    original = CoachPersonaVersion.instance_method(:release_evidence_valid?)
    CoachPersonaVersion.define_method(:release_evidence_valid?) do
      evidence_calls += 1
      original.bind_call(self)
    end
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    query_count = count_select_queries do
      payload = CohortReleases::StudioSerializer.new(cohort: Cohort.find(cohort.id), actor: owner).call
      assert_equal 25, payload.fetch(:releases).length
      assert_equal({ limit: 25, total_count: 100, truncated: true }, payload.fetch(:history))
      assert payload.fetch(:releases).all? { |release| release.fetch(:integrity_valid) }
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator query_count, :<=, 35, "release history issued #{query_count} SELECT queries"
    assert_operator evidence_calls, :<=, 2, "release evidence was re-evaluated #{evidence_calls} times"
    assert_operator elapsed, :<=, 3.5, "release history took #{elapsed.round(3)} seconds"
  ensure
    CoachPersonaVersion.define_method(:release_evidence_valid?, original) if original
  end

  test "direct execution creation cannot forge linkage to its release" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    result = run_seal(
      cohort,
      owner,
      seal_input(cohort, assignment, persona_version, experience_version),
      request_key: "linked-operation"
    )
    forged = result.execution.dup
    forged.normalized_input = forged.normalized_input.merge("expected_persona_version_id" => persona_version.id + 1)
    forged.normalized_input_digest = CoachOperations::Contract.digest(forged.normalized_input)
    forged.invocation_fingerprint = CoachOperations::Contract.invocation_fingerprint(
      cohort_id: cohort.id,
      coach_workspace_id: cohort.coach_workspace_id,
      actor_user_id: owner.id,
      actor_role_snapshot: "owner",
      operation_key: forged.operation_key,
      operation_version: forged.operation_version,
      normalized_input: forged.normalized_input
    )
    forged.request_fingerprint = CoachOperations::Contract.request_fingerprint(
      request_key: forged.request_key,
      invocation_fingerprint: forged.invocation_fingerprint
    )

    refute forged.valid?
    assert_includes forged.errors[:normalized_input], "does not match the sealed release"

    forged = result.execution.dup
    forged.completed_at = result.release.released_at + 1.hour
    refute forged.valid?
    assert_includes forged.errors[:completed_at], "must match the linked release"
  end

  test "database composite keys reject an execution from another workspace" do
    owner, cohort, assignment, persona_version, experience_version = governed_components
    result = run_seal(
      cohort,
      owner,
      seal_input(cohort, assignment, persona_version, experience_version),
      request_key: "tenant-bound-operation"
    )
    other_owner = persona_user
    other_workspace = CoachWorkspaces::Provisioner.ensure_for!(other_owner)
    forged = result.execution.attributes.except("id")
    forged["coach_workspace_id"] = other_workspace.id
    begin
      CoachOperationExecution.connection.execute(
        "ALTER TABLE coach_operation_executions DISABLE TRIGGER coach_operation_executions_immutable"
      )
      CoachOperationExecution.where(id: result.execution.id).delete_all
      CoachOperationExecution.connection.execute(
        "ALTER TABLE coach_operation_executions ENABLE TRIGGER coach_operation_executions_immutable"
      )
      assert_raises(ActiveRecord::InvalidForeignKey) do
        CoachOperationExecution.transaction(requires_new: true) do
          CoachOperationExecution.insert_all!([ forged ])
        end
      end

      forged["coach_workspace_id"] = cohort.coach_workspace_id
      forged["actor_user_id"] = other_owner.id
      assert_raises(ActiveRecord::InvalidForeignKey) do
        CoachOperationExecution.transaction(requires_new: true) do
          CoachOperationExecution.insert_all!([ forged ])
        end
      end
    ensure
      CoachOperationExecution.connection.execute(
        "ALTER TABLE coach_operation_executions ENABLE TRIGGER coach_operation_executions_immutable"
      )
    end
  end

  private

  def governed_components
    owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    cohort = Cohort.create!(
      name: "Coach operation #{SecureRandom.hex(4)}",
      status: "active",
      created_by_user: owner,
      coach_workspace: workspace
    )
    persona = create_persona(
      creator: owner,
      name: "Operation persona #{SecureRandom.hex(4)}",
      workspace: workspace
    )
    persona_version = publish_persona(persona, actor: owner)
    assignment = CohortPersonaAssignment.create!(
      cohort: cohort,
      coach_workspace: workspace,
      coach_persona: persona,
      coach_persona_version: persona_version,
      assigned_by_user: owner
    )
    configuration = cohort.cohort_experience_configuration
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    experience_version = publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: configuration.reload.draft_revision,
      expected_current_version_id: nil
    )
    [ owner, cohort, assignment, persona_version, experience_version ]
  end

  def seal_input(cohort, assignment, persona_version, experience_version)
    candidate = CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call
    {
      "expected_assignment_id" => assignment.id,
      "expected_bundle_digest" => candidate.bundle_digest,
      "expected_experience_version_id" => experience_version.id,
      "expected_latest_release_id" => cohort.cohort_releases.order(release_number: :desc).pick(:id),
      "expected_persona_version_id" => persona_version.id,
      "expected_tool_registry_digest" => CohortReleases::Contract.digest(candidate.tool_registry_snapshot),
      "expected_tool_registry_version" => CohortReleases::Contract::TOOL_REGISTRY_VERSION
    }
  end

  def run_seal(cohort, owner, input, request_key:)
    CoachOperations::Runner.new(cohort: cohort, actor: owner).call!(
      operation_key: "cohort.release.seal",
      operation_version: 1,
      input: input,
      request_key: request_key
    )
  end

  def count_select_queries
    count = 0
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      next if payload[:cached] || payload[:name].to_s.match?(/SCHEMA|CACHE/)

      count += 1 if payload[:sql].to_s.lstrip.start_with?("SELECT")
    end
    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { yield }
    count
  end
end
