# frozen_string_literal: true

module PersonaTestHelper
  def persona_user(role: "coach", email: nil)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(8)}",
      email: email || "#{SecureRandom.hex(8)}@example.com",
      role: role,
      invitation_status: "accepted"
    )
  end

  def persona_configuration(assistant_name: "Mia", coach_name: "Mrs. Mel")
    Mia::PersonaSchema.default_configuration(
      assistant_name: assistant_name,
      human_coach_name: coach_name,
      human_coach_title: "Household CFO coach"
    )
  end

  def persona_phrase_artifact(attributes = {}, source_user_id: 1, provenance: "coach_authored")
    defaults = {
      "text" => "Approved phrase",
      "meaning" => "Coach-authored wording with a documented meaning.",
      "allowed_contexts" => [ "general" ],
      "prohibited_contexts" => [ "crisis" ],
      "frequency" => "rare",
      "caution" => "Use only in the documented context."
    }
    Mia::PersonaSchema.build_phrase_artifact(
      defaults.merge(attributes.stringify_keys),
      source_user_id: source_user_id,
      provenance: provenance
    )
  end

  def create_persona(creator: persona_user, name: "Household CFO", config: nil, workspace: nil)
    CoachPersona.create!(
      name: name,
      description: "A coach-approved participant experience.",
      draft_config: config || persona_configuration,
      created_by_user: creator,
      coach_workspace: workspace
    )
  end

  def cohort_for(creator, name:, status: "active")
    Cohort.create!(name: name, status: status, created_by_user: creator)
  end

  def publish_persona(persona, actor:, evaluator: actor, reviewer: actor, audience_reviewer: reviewer)
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: actor)
    preview = publisher.preview!(expected_draft_revision: persona.reload.draft_revision)
    evidence = persona_release_evidence(
      persona, actor: actor, evaluator: evaluator, reviewer: reviewer, audience_reviewer: audience_reviewer
    )
    publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: persona.current_published_version_id,
      **evidence
    )
  end

  def persona_release_evidence(persona, actor:, evaluator: actor, reviewer: actor, audience_reviewer: reviewer)
    candidate = Mia::PersonaRelease::CandidateBuilder.new(persona: persona, actor: evaluator).call!
    behavioral = Mia::PersonaRelease::BehavioralPreviewRecorder.new(persona: persona, actor: actor).call!(
      candidate: candidate,
      preview: {
        status: "ready", source: "live_model", sample_prompt: "Help this fictional household plan.",
        sample_reply: "Review the confirmed plan and choose one next step.", model_identifier: "test-model",
        context_digest: Mia::PersonaPreviewer.context_digest
      }
    )
    run = Mia::PersonaRelease::Runner.new(persona: persona, actor: evaluator).call!
    approval = Mia::PersonaRelease::RunApprover.new(run: run, actor: reviewer).call!(
      decision: "approved", expected_run_digest: run.run_digest
    )
    Array(candidate.phrase_artifacts_snapshot).each do |artifact|
      Mia::PersonaRelease::AudienceAttester.new(persona: persona, actor: audience_reviewer).call!(
        candidate_digest: candidate.manifest_digest, artifact_id: artifact.fetch("artifact_id"),
        artifact_fingerprint: artifact.fetch("fingerprint"), decision: "approved"
      )
    end
    {
      expected_release_candidate_digest: candidate.manifest_digest,
      expected_evaluation_run_digest: run.run_digest,
      expected_evaluation_approval_digest: approval.approval_digest,
      expected_behavioral_preview_digest: behavioral.evidence_digest
    }
  end


  def approved_content_item(owner:, title: "Ask one clear question", kind: "guidance", content: "Ask one clear question, then offer one practical next step.", scope: "coach", always_on: false)
    item = CoachContentItem.create!(
      title: title,
      scope: scope,
      kind: kind,
      draft_content: content,
      draft_always_on: always_on,
      created_by_user: owner
    )
    item.approve!(actor: owner, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    item
  end

  def published_content_pack(owner:, items:, name: "Coach method", pack_kind: "coaching_method", scope: "coach")
    pack = CoachContentPack.create!(
      name: name,
      description: "Reviewed coaching content.",
      scope: scope,
      pack_kind: pack_kind,
      created_by_user: owner
    )
    pack.replace_draft_item_versions!(items.map(&:current_approved_version), actor: owner)
    pack.publish!(
      actor: owner,
      expected_draft_revision: pack.draft_revision,
      expected_draft_manifest_digest: pack.draft_manifest_digest,
      expected_current_version_id: pack.current_published_version_id
    )
    pack
  end
end
