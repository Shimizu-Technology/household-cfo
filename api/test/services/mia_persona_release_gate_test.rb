# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaReleaseGateTest < ActiveSupport::TestCase
  include PersonaTestHelper

  class FallbackAdapter < Mia::PersonaRelease::BehavioralAdapter
    def kind = "test_fallback"

    def call(evaluation_case:, persona:, candidate:)
      Response.new(
        output: "Review the facts and options, then choose your next step.",
        metadata: { "source" => "deterministic_fallback" },
        fallback_only: true
      )
    end
  end

  test "gate v2 publication seals a current passed run and human approval while legacy publication stays explicit" do
    owner = persona_user
    persona = create_persona(creator: owner)

    legacy = publish_persona(persona, actor: owner)
    assert_equal "gate_v1", legacy.release_gate_version
    assert legacy.release_evidence_valid?
    assert_nil legacy.release_evidence_digest

    persona.update!(description: "Prepare the exact next release.")
    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).call!
    assert_equal "passed", run.status
    assert run.passed_and_valid?
    approval = approve(run, owner)

    version = Mia::PersonaPublisher.new(persona: persona, actor: owner).publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: legacy.id,
      expected_release_candidate_digest: run.release_candidate.manifest_digest,
      expected_evaluation_run_digest: run.run_digest,
      expected_evaluation_approval_digest: approval.approval_digest
    )

    assert_equal "gate_v2", version.release_gate_version
    assert version.release_evidence_valid?
    assert_equal run.id, version.evaluation_run.id
    assert_equal approval.id, version.evaluation_approval.id
    assert_equal "gate_v2", persona.reload.release_gate_version
    assert_equal "gate_v2", persona.publication_events.order(:id).last.release_gate_version

    persona.update!(description: "Evidence is required after adoption.")
    error = assert_raises(Mia::PersonaPublisher::PublicationError) { publish_persona(persona, actor: owner) }
    assert_equal "This persona requires a passed and approved gate_v2 evaluation before publishing", error.message
    refute persona.update(release_gate_version: "gate_v1")
    assert_includes persona.errors[:release_gate_version], "cannot be downgraded after gate_v2 adoption"
    assert_equal "gate_v2", persona.reload.release_gate_version
    rollback_error = assert_raises(Mia::PersonaRollback::RollbackError) do
      Mia::PersonaRollback.new(persona: persona, target_version: legacy, actor: owner).call(
        expected_current_version_id: version.id,
        expected_draft_revision: persona.draft_revision
      )
    end
    assert_equal "A gate_v2 persona cannot roll back to legacy release evidence", rollback_error.message
  end

  test "fallback-only behavioral output can never pass or be approved" do
    owner = persona_user
    persona = create_persona(creator: owner)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner, adapter: FallbackAdapter.new).call!

    assert_equal "failed", run.status
    assert run.results.all?(&:fallback_only?)
    refute run.passed_and_valid?
    error = assert_raises(Mia::PersonaRelease::RunApprover::Error) { approve(run, owner) }
    assert_equal "Only the exact intact passed evaluation can be approved", error.message
  end

  test "every phrase is bound to the exact candidate audience before publication" do
    owner = persona_user
    config = persona_configuration(assistant_name: "Audience bound assistant")
    config["identity"]["audience"] = "Adults in Mrs. Mel's Guam household finance cohort."
    config["culture"]["locale_label"] = "Guam"
    config["phrases"] = [
      persona_phrase_artifact(
        {
          "text" => "Håfa adai",
          "meaning" => "The coach's reviewed greeting.",
          "allowed_contexts" => [ "greeting" ],
          "prohibited_contexts" => [ "crisis" ]
        },
        source_user_id: owner.id
      )
    ]
    persona = create_persona(creator: owner, config: config)
    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).call!
    approval = approve(run, owner)

    error = assert_raises(Mia::PersonaPublisher::PublicationError) do
      publish_v2(persona, owner, preview, run, approval)
    end
    assert_equal "Every phrase requires an approval for this exact audience and culture", error.message

    artifact = run.release_candidate.phrase_artifacts_snapshot.sole
    attestation = Mia::PersonaRelease::AudienceAttester.new(persona: persona, actor: owner).call!(
      candidate_digest: run.release_candidate.manifest_digest,
      artifact_id: artifact.fetch("artifact_id"),
      artifact_fingerprint: artifact.fetch("fingerprint"),
      decision: "approved"
    )
    assert attestation.self_review?
    version = publish_v2(persona, owner, preview, run, approval)
    assert version.release_evidence_valid?

    changed = persona.draft_config.deep_dup
    changed["identity"]["audience"] = "Adults in a new regional cohort."
    persona.update!(draft_config: changed)
    refute run.release_candidate.current_for?(persona)
    readiness = Mia::PersonaRelease::Readiness.new(persona: persona).call
    refute readiness.fetch(:ready)
    assert_nil readiness.fetch(:candidate)
  end

  test "self review is limited to the sole workspace owner" do
    first_owner = persona_user
    second_owner = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(first_owner)
    workspace.coach_workspace_memberships.create!(user: second_owner, role: "owner")
    persona = create_persona(creator: first_owner, workspace: workspace)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: first_owner).call!

    error = assert_raises(Mia::PersonaRelease::RunApprover::Error) { approve(run, first_owner) }
    assert_equal "A different workspace owner or reviewer must complete this review", error.message

    approval = approve(run, second_owner)
    refute approval.self_review?
    assert approval.integrity_valid?
  end

  test "tampering any stored result or approval makes release evidence fail closed" do
    owner = persona_user
    persona = create_persona(creator: owner)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).call!
    approval = approve(run, owner)
    assert run.passed_and_valid?
    assert approval.integrity_valid?

    result = run.results.first
    assert_not result.update(output: "Forged output")
    result.update_column(:output, "Forged output")
    refute result.reload.integrity_valid?
    refute run.reload.passed_and_valid?
    refute approval.reload.integrity_valid?
  end

  test "publication requires the latest run against the current stored case suite" do
    owner = persona_user
    persona = create_persona(creator: owner)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).call!
    approval = approve(run, owner)
    assert run.current_suite_pass?

    custom = persona.evaluation_cases.new(
      coach_workspace: persona.coach_workspace,
      created_by_user: owner,
      name: "New long-context case",
      case_kind: "custom",
      prompt: "Keep the household plan in context across this follow-up.",
      assertions: [ { "type" => "not_fallback" } ],
      required: false,
      active: true
    )
    custom.case_digest = CoachPersonaEvaluationCase.digest_for(custom)
    custom.save!
    refute run.reload.current_suite_pass?
    assert approval.reload.integrity_valid?, "historical approval integrity should remain stable"

    replacement = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).call!
    replacement_approval = approve(replacement, owner)
    assert replacement.current_suite_pass?
    fallback = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner, adapter: FallbackAdapter.new).call!
    assert_equal "failed", fallback.status

    error = assert_raises(Mia::PersonaRelease::Evidence::Error) do
      Mia::PersonaRelease::Evidence.new(persona: persona).verify_current!(
        candidate_digest: replacement.release_candidate.manifest_digest,
        run_digest: replacement.run_digest,
        approval_digest: replacement_approval.approval_digest
      )
    end
    assert_equal "A newer evaluation run exists for this release candidate", error.message
  end

  test "custom assertions are typed and bounded" do
    owner = persona_user
    persona = create_persona(creator: owner)
    valid = persona.evaluation_cases.new(
      coach_workspace: persona.coach_workspace,
      created_by_user: owner,
      name: "Manual money decision",
      case_kind: "custom",
      prompt: "Can I afford a new car?",
      assertions: [ { "type" => "includes", "value" => "review" }, { "type" => "not_fallback" } ],
      required: false
    )
    valid.case_digest = CoachPersonaEvaluationCase.digest_for(valid)
    assert valid.save

    invalid = persona.evaluation_cases.new(
      coach_workspace: persona.coach_workspace,
      created_by_user: owner,
      name: "Unsafe regex assertion",
      case_kind: "custom",
      prompt: "Test",
      assertions: [ { "type" => "regex", "value" => ".*" } ],
      required: false,
      case_digest: "0" * 64
    )
    refute invalid.valid?
    assert_includes invalid.errors[:assertions], "contains an unsupported assertion type"
  end

  test "historical v2 release evidence supports a safe rollback and tampered evidence blocks it" do
    owner = persona_user
    persona = create_persona(creator: owner)
    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).call!
    approval = approve(run, owner)
    v2 = publish_v2(persona, owner, preview, run, approval)

    persona.update!(description: "A later evaluated release.")
    later_preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    later_run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).call!
    later_approval = approve(later_run, owner)
    latest = publish_v2(persona, owner, later_preview, later_run, later_approval)
    restored = Mia::PersonaRollback.new(persona: persona, target_version: v2, actor: owner).call(
      expected_current_version_id: latest.id,
      expected_draft_revision: persona.draft_revision
    )
    assert_equal "gate_v2", restored.release_gate_version
    assert restored.release_evidence_valid?

    approval.update_column(:approval_digest, "f" * 64)
    refute v2.reload.release_evidence_valid?
    error = assert_raises(Mia::PersonaRollback::RollbackError) do
      Mia::PersonaRollback.new(persona: persona, target_version: v2, actor: owner).call(
        expected_current_version_id: restored.id,
        expected_draft_revision: persona.reload.draft_revision
      )
    end
    assert_equal "Rollback target release evidence is invalid", error.message
  end

  private

  def approve(run, actor)
    Mia::PersonaRelease::RunApprover.new(run: run, actor: actor).call!(
      decision: "approved",
      expected_run_digest: run.run_digest
    )
  end

  def publish_v2(persona, owner, preview, run, approval)
    Mia::PersonaPublisher.new(persona: persona, actor: owner).publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: persona.current_published_version_id,
      expected_release_candidate_digest: run.release_candidate.manifest_digest,
      expected_evaluation_run_digest: run.run_digest,
      expected_evaluation_approval_digest: approval.approval_digest
    )
  end
end
