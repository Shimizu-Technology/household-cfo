# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaPersonaReleaseGateTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ActiveJob::TestHelper

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

  class LiveTestAdapter < Mia::PersonaRelease::BehavioralAdapter
    def kind = "test_live_model"

    def call(evaluation_case:, persona:, candidate:)
      Response.new(
        output: "Review the exact candidate facts and options before choosing the next step.",
        metadata: { "source" => "live_model", "candidate_digest" => candidate.manifest_digest },
        fallback_only: false
      )
    end
  end

  test "gate v2 publication seals a current passed run and human approval while legacy publication stays explicit" do
    owner = persona_user
    persona = create_persona(creator: owner)

    legacy = persona.versions.create!(
      version_number: 1, config: persona.draft_config.deep_dup,
      config_digest: Mia::PersonaSchema.digest(persona.draft_config),
      content_manifest_digest: CoachPersonaVersion.content_manifest_digest_for([]),
      phrase_manifest_digest: Mia::PhraseManifest.digest_for([]), published_by_user: owner,
      release_gate_version: "gate_v1"
    )
    legacy.seal_manifests!
    persona.update!(current_published_version: legacy)
    assert_equal "gate_v1", legacy.release_gate_version
    assert legacy.release_evidence_valid?
    assert_nil legacy.release_evidence_digest

    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Steady and reassuring." }))
    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).call!
    assert_equal "passed", run.status
    assert run.passed_and_valid?
    approval = approve(run, owner)
    behavioral = behavioral_preview_for(run.release_candidate, owner)

    version = Mia::PersonaPublisher.new(persona: persona, actor: owner).publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: legacy.id,
      expected_release_candidate_digest: run.release_candidate.manifest_digest,
      expected_evaluation_run_digest: run.run_digest,
      expected_evaluation_approval_digest: approval.approval_digest,
      expected_behavioral_preview_digest: behavioral.evidence_digest
    )

    assert_equal "gate_v2", version.release_gate_version
    assert version.release_evidence_valid?
    assert_equal run.id, version.evaluation_run.id
    assert_equal approval.id, version.evaluation_approval.id
    assert_equal "gate_v2", persona.reload.release_gate_version
    assert_equal "gate_v2", persona.publication_events.order(:id).last.release_gate_version

    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Calm and focused." }))
    missing_evidence_preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    error = assert_raises(Mia::PersonaPublisher::PublicationError) do
      Mia::PersonaPublisher.new(persona: persona, actor: owner).publish!(
        expected_preview_digest: missing_evidence_preview.fetch(:digest),
        expected_draft_revision: persona.draft_revision,
        expected_current_version_id: version.id
      )
    end
    assert_equal "Complete release evidence is required for every publication", error.message
    refute persona.update(release_gate_version: "gate_v1")
    assert_includes persona.errors[:release_gate_version], "cannot be downgraded after gate_v2 adoption"
    assert_equal "gate_v2", persona.reload.release_gate_version
    rollback_error = assert_raises(Mia::PersonaRollback::RollbackError) do
      Mia::PersonaRollback.new(persona: persona, target_version: legacy, actor: owner).call(
        expected_current_version_id: version.id,
        expected_draft_revision: persona.draft_revision
      )
    end
    assert_equal "Historical gate_v1 versions remain readable but cannot be republished", rollback_error.message
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
    readiness = Mia::PersonaRelease::Readiness.new(persona: persona, actor: owner).call
    assert_equal "Adults in Mrs. Mel's Guam household finance cohort.", readiness.dig(:candidate, :audience_snapshot, "audience")
    phrase_review = readiness.fetch(:phrase_audience_reviews).sole
    assert_equal "Håfa adai", phrase_review.dig(:phrase, "text")
    assert_equal "coach_authored", phrase_review.dig(:provenance, :kind)
    assert_equal owner.id, phrase_review.dig(:reviewer, :id)
    assert_equal attestation.reviewed_at, phrase_review.fetch(:reviewed_at)
    assert_equal attestation.attestation_digest, phrase_review.fetch(:attestation_digest)
    version = publish_v2(persona, owner, preview, run, approval)
    assert version.release_evidence_valid?

    changed = persona.draft_config.deep_dup
    changed["identity"]["audience"] = "Adults in a new regional cohort."
    persona.update!(draft_config: changed)
    refute run.release_candidate.current_for?(persona)
    readiness = Mia::PersonaRelease::Readiness.new(persona: persona, actor: owner).call
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
      active: true,
      request_key: "custom-latest-#{SecureRandom.uuid}",
      request_fingerprint: "a" * 64
    )
    custom.case_digest = CoachPersonaEvaluationCase.digest_for(custom)
    custom.save!
    refute run.reload.current_suite_pass?
    assert approval.reload.integrity_valid?, "historical approval integrity should remain stable"

    hybrid = Mia::PersonaRelease::HybridBehavioralAdapter.new(live: LiveTestAdapter.new)
    replacement = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner, adapter: hybrid).call!
    replacement_approval = approve(replacement, owner)
    assert replacement.current_suite_pass?
    fallback = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner, adapter: FallbackAdapter.new).call!
    assert_equal "failed", fallback.status

    error = assert_raises(Mia::PersonaRelease::Evidence::Error) do
      Mia::PersonaRelease::Evidence.new(persona: persona).verify_current!(
        candidate_digest: replacement.release_candidate.manifest_digest,
        run_digest: replacement.run_digest,
        approval_digest: replacement_approval.approval_digest,
        behavioral_preview_digest: behavioral_preview_for(replacement.release_candidate, owner).evidence_digest
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
      required: false,
      request_key: "custom-valid-#{SecureRandom.uuid}",
      request_fingerprint: "b" * 64
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
      request_key: "custom-invalid-#{SecureRandom.uuid}",
      request_fingerprint: "c" * 64,
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

    persona.update!(draft_config: persona.draft_config.deep_merge("voice" => { "energy" => "Warm and encouraging." }))
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

  test "queued evaluation fails closed when the requester loses edit access" do
    owner = persona_user
    editor = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    membership = workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    persona = create_persona(creator: owner, workspace: workspace)
    queued = Mia::PersonaRelease::Runner.new(persona: persona, actor: editor)
      .enqueue!(request_key: SecureRandom.uuid)

    membership.update!(role: "viewer")
    run = Mia::PersonaRelease::Runner.execute_pending!(queued.run.id, lease_token: queued.run.lease_token)

    assert_equal "error", run.reload.status
    assert run.run_digest.present?
    assert_empty run.results
  end

  test "active leases reconcile without duplicate jobs and expired leases recover with a new owner token" do
    owner = persona_user
    persona = create_persona(creator: owner)
    request_id = SecureRandom.uuid
    first = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).enqueue!(request_key: request_id)
    old_token = first.run.lease_token

    replay = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).enqueue!(request_key: request_id)
    assert replay.replayed
    refute replay.enqueued
    assert_equal old_token, replay.run.lease_token

    first.run.update_columns(lease_expires_at: 1.minute.ago)
    recovery = Mia::PersonaRelease::Runner.new(persona: persona, actor: owner).enqueue!(request_key: request_id)
    assert recovery.enqueued
    refute_equal old_token, recovery.run.lease_token
    assert_equal "pending", Mia::PersonaRelease::Runner.execute_pending!(
      recovery.run.id, lease_token: old_token
    ).status
    completed = Mia::PersonaRelease::Runner.execute_pending!(
      recovery.run.id, lease_token: recovery.run.lease_token
    )
    assert_equal "passed", completed.status
  end

  test "revoked reviewer authority blocks unconsumed evidence while historical evidence remains valid" do
    owner = persona_user
    editor = persona_user
    reviewer = persona_user
    workspace = CoachWorkspaces::Provisioner.ensure_for!(owner)
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    membership = workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    persona = create_persona(creator: owner, workspace: workspace)
    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: editor).call!
    approval = approve(run, reviewer)
    behavioral = behavioral_preview_for(run.release_candidate, owner)
    membership.update!(role: "viewer")

    error = assert_raises(Mia::PersonaPublisher::PublicationError) do
      Mia::PersonaPublisher.new(persona: persona, actor: owner).publish!(
        expected_preview_digest: preview.fetch(:digest), expected_draft_revision: persona.draft_revision,
        expected_current_version_id: nil, expected_release_candidate_digest: run.release_candidate.manifest_digest,
        expected_evaluation_run_digest: run.run_digest, expected_evaluation_approval_digest: approval.approval_digest,
        expected_behavioral_preview_digest: behavioral.evidence_digest
      )
    end
    assert_includes error.message, "reviewer no longer has workspace review access"
  end

  test "behavioral preview evidence is immutable bounded and sealed into publication evidence" do
    owner = persona_user
    persona = create_persona(creator: owner)
    version = publish_persona(persona, actor: owner)
    evidence = version.behavioral_preview_evidence

    assert evidence.integrity_valid?
    assert_equal evidence.evidence_digest, version.behavioral_preview_digest
    refute evidence.update(output: "forged")
    evidence.update_column(:output, "forged")
    refute evidence.reload.integrity_valid?
    refute version.reload.release_evidence_valid?
  end

  test "publishing identical manifests is rejected as a no-op" do
    owner = persona_user
    persona = create_persona(creator: owner)
    version = publish_persona(persona, actor: owner)
    preview = Mia::PersonaPublisher.new(persona: persona, actor: owner)
      .preview!(expected_draft_revision: persona.draft_revision)

    error = assert_raises(Mia::PersonaPublisher::PublicationError) do
      Mia::PersonaPublisher.new(persona: persona, actor: owner).publish!(
        expected_preview_digest: preview.fetch(:digest), expected_draft_revision: persona.draft_revision,
        expected_current_version_id: version.id
      )
    end
    assert_equal "There are no persona changes to publish", error.message
  end

  private

  def approve(run, actor)
    Mia::PersonaRelease::RunApprover.new(run: run, actor: actor).call!(
      decision: "approved",
      expected_run_digest: run.run_digest
    )
  end

  def publish_v2(persona, owner, preview, run, approval)
    behavioral = behavioral_preview_for(run.release_candidate, owner)
    Mia::PersonaPublisher.new(persona: persona, actor: owner).publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: persona.current_published_version_id,
      expected_release_candidate_digest: run.release_candidate.manifest_digest,
      expected_evaluation_run_digest: run.run_digest,
      expected_evaluation_approval_digest: approval.approval_digest,
      expected_behavioral_preview_digest: behavioral.evidence_digest
    )
  end

  def behavioral_preview_for(candidate, actor)
    Mia::PersonaRelease::BehavioralPreviewRecorder.new(persona: candidate.coach_persona, actor: actor).call!(
      candidate: candidate,
      preview: {
        status: "ready", source: "live_model", sample_prompt: "Test the exact candidate.",
        sample_reply: "Review the exact facts and choose one step.", model_identifier: "test-model",
        context_digest: Mia::PersonaPreviewer.context_digest
      }
    )
  end
end
