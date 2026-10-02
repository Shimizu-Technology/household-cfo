# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaApprovedSourcePhrasePromotionTest < ActiveSupport::TestCase
  include PersonaTestHelper

  setup do
    @owner = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @owner).call
    @editor = persona_user
    @reviewer = persona_user
    @workspace.coach_workspace_memberships.create!(user: @editor, role: "editor")
    @workspace.coach_workspace_memberships.create!(user: @reviewer, role: "reviewer")
    @source_text = "Håfa adai. Keep one practical next step."
    @source, @candidate, @version = approved_phrase_source(owner: @owner, source_text: @source_text)
    @payload = {
      "text" => "Håfa adai",
      "meaning" => "A reviewed greeting from the coach's source.",
      "allowed_contexts" => [ "greeting" ],
      "prohibited_contexts" => [ "crisis" ],
      "frequency" => "rare",
      "caution" => "Use only as a greeting."
    }
  end

  test "requires exact wording in both approved content and parsed source evidence" do
    proposal = with_source_download(@source_text) { create_proposal }

    assert_equal "draft", proposal.status
    assert_equal Digest::SHA256.hexdigest("Håfa adai".b), proposal.phrase_digest
    assert_equal 0, proposal.evidence_start_byte
    assert_equal "text", proposal.evidence_locator.fetch("type")
    assert proposal.valid?

    error = assert_raises(Mia::PhraseProposalWriter::Error) do
      with_source_download(@source_text) { create_proposal(@payload.merge("text" => "håfa adai")) }
    end
    assert_equal "phrase_approved_content_not_exact", error.code

    unapproved_sentence = assert_raises(Mia::PhraseProposalWriter::Error) do
      with_source_download(@source_text) do
        create_proposal(@payload.merge("text" => "Keep one practical next step"))
      end
    end
    assert_equal "phrase_approved_content_not_exact", unapproved_sentence.code

    lowercase_source, lowercase_candidate, lowercase_version = approved_phrase_source(
      owner: @owner,
      source_text: @source_text,
      candidate_title: "Reviewed lowercase greeting",
      candidate_content: "Håfa adai\nhåfa adai"
    )
    source_mismatch = assert_raises(Mia::PhraseProposalWriter::Error) do
      with_source_download(@source_text) do
        writer.create!(
          source_id: lowercase_source.id,
          candidate_id: lowercase_candidate.id,
          content_item_version_id: lowercase_version.id,
          phrase_payload: @payload.merge("text" => "håfa adai")
        )
      end
    end
    assert_equal "phrase_source_not_exact", source_mismatch.code
  end

  test "identical create replay returns the existing integrity-valid proposal" do
    proposal = with_source_download(@source_text) { create_proposal }
    replay = with_source_download(@source_text) { create_proposal }

    assert_equal proposal.id, replay.id
    assert replay.integrity_valid?
    assert_equal 1, CoachPhraseProposal.where(
      coach_workspace_id: @workspace.id,
      proposed_by_user_id: @editor.id,
      proposal_digest: proposal.proposal_digest
    ).count
  end

  test "editing a draft into an existing sealed proposal returns a stable duplicate error" do
    rejected = with_source_download(@source_text) { create_proposal }
    rejected = with_source_download(@source_text) do
      writer.submit!(proposal_id: rejected.id, expected_revision: rejected.revision, expected_digest: rejected.proposal_digest)
    end
    with_source_download(@source_text) do
      Mia::PhraseAttester.new(actor: @reviewer, workspace: @workspace).call!(
        proposal_id: rejected.id, decision: "rejected", expected_digest: rejected.proposal_digest
      )
    end
    draft = with_source_download(@source_text) do
      create_proposal(@payload.merge("caution" => "A distinct draft."))
    end

    error = assert_raises(Mia::PhraseProposalWriter::Error) do
      with_source_download(@source_text) do
        writer.update!(
          proposal_id: draft.id,
          expected_revision: draft.revision,
          expected_digest: draft.proposal_digest,
          phrase_payload: @payload
        )
      end
    end

    assert_equal "phrase_proposal_duplicate", error.code
    assert_equal "draft", draft.reload.status
    assert_equal "A distinct draft.", draft.phrase_payload.fetch("caution")
  end

  test "reviewed phrase wording cannot advance after acceptance" do
    proposal = with_source_download(@source_text) { create_proposal }
    item = @version.coach_content_item
    item.assign_attributes(draft_content: "Håfa adai. A newer reviewed version.")

    refute item.valid?
    assert_includes item.errors[:base], "approved source phrase wording is read-only"
    assert_equal proposal.id, with_source_download(@source_text) { create_proposal }.id
    assert_equal @version.id, item.reload.current_approved_version_id
  end

  test "identical create replay survives source unavailability" do
    proposal = with_source_download(@source_text) { create_proposal }
    @source.update!(status: "deletion_pending", deletion_requested_at: Time.current)

    assert_equal proposal.id, create_proposal.id
    changed = assert_raises(Mia::PhraseProposalWriter::Error) do
      create_proposal(@payload.merge("caution" => "This is a different request."))
    end
    assert_equal "phrase_source_chain_invalid", changed.code
  end

  test "identical create replay does not require private storage to remain available" do
    proposal = with_source_download(@source_text) { create_proposal }
    original_download = S3Service.method(:download_to_io!)
    S3Service.define_singleton_method(:download_to_io!) do |*_args|
      raise S3Service::MissingConfigurationError
    end

    assert_equal proposal.id, create_proposal.id
    changed = assert_raises(Mia::PhraseProposalWriter::Error) do
      create_proposal(@payload.merge("caution" => "This is a different request."))
    end
    assert_equal "phrase_source_unavailable", changed.code
  ensure
    S3Service.define_singleton_method(:download_to_io!, original_download) if defined?(original_download) && original_download
  end

  test "rechecks metadata bytes checksum parser locator and current approved chain" do
    mismatch = assert_raises(Mia::PhraseProposalWriter::Error) do
      with_source_download("Håfa adai changed.") { create_proposal }
    end
    assert_equal "phrase_source_checksum_mismatch", mismatch.code

    original = ContentSources::UploadValidator.method(:validate_metadata!)
    ContentSources::UploadValidator.define_singleton_method(:validate_metadata!) { |**| raise ContentSources::Error, "file_too_large" }
    too_large = assert_raises(Mia::PhraseProposalWriter::Error) do
      with_source_download(@source_text) { create_proposal(@payload.merge("caution" => "Metadata validation.")) }
    end
    assert_equal "phrase_source_file_too_large", too_large.code
  ensure
    ContentSources::UploadValidator.define_singleton_method(:validate_metadata!, original) if defined?(original) && original
  end

  test "rejects archived phrase items" do
    item = @version.coach_content_item
    item.update!(archived_at: Time.current)
    archived = assert_raises(Mia::PhraseProposalWriter::Error) do
      with_source_download(@source_text) do
        writer.create!(
          source_id: @source.id,
          candidate_id: @candidate.id,
          content_item_version_id: @version.id,
          phrase_payload: @payload
        )
      end
    end
    assert_equal "phrase_source_chain_invalid", archived.code
  end

  test "editor submits reviewer attests and reviewer promotes without general edit permission" do
    proposal = with_source_download(@source_text) { create_proposal }
    proposal = with_source_download(@source_text) do
      writer.submit!(proposal_id: proposal.id, expected_revision: proposal.revision, expected_digest: proposal.proposal_digest)
    end
    assert_equal "submitted", proposal.status

    attestation = with_source_download(@source_text) do
      Mia::PhraseAttester.new(actor: @reviewer, workspace: @workspace).call!(
        proposal_id: proposal.id,
        decision: "approved",
        expected_digest: proposal.proposal_digest
      )
    end
    assert attestation.integrity_valid?
    refute attestation.self_review

    persona = create_persona(creator: @owner, workspace: @workspace)
    promotion = with_source_download(@source_text) do
      Mia::PersonaPhrasePromoter.new(actor: @reviewer, workspace: @workspace).promote!(
        persona_id: persona.id,
        proposal_id: proposal.id,
        expected_draft_revision: persona.draft_revision
      )
    end
    persona.reload
    artifact = persona.draft_config.fetch("phrases").sole
    assert_equal "approved_source", artifact.fetch("provenance")
    assert_equal promotion.artifact_id.to_s, artifact.fetch("artifact_id")
    assert_equal @reviewer.id, artifact.fetch("source_user_id")
    refute @workspace.allows?(@reviewer, :edit)
  end

  test "initial promotion revalidates the exact source after attestation" do
    proposal = with_source_download(@source_text) { create_proposal }
    proposal = with_source_download(@source_text) do
      writer.submit!(proposal_id: proposal.id, expected_revision: proposal.revision, expected_digest: proposal.proposal_digest)
    end
    with_source_download(@source_text) do
      Mia::PhraseAttester.new(actor: @reviewer, workspace: @workspace).call!(
        proposal_id: proposal.id,
        decision: "approved",
        expected_digest: proposal.proposal_digest
      )
    end
    persona = create_persona(creator: @owner, workspace: @workspace)

    error = assert_raises(Mia::PersonaPhrasePromoter::Error) do
      with_source_download("Håfa adai. Changed after review.") do
        Mia::PersonaPhrasePromoter.new(actor: @reviewer, workspace: @workspace).promote!(
          persona_id: persona.id,
          proposal_id: proposal.id,
          expected_draft_revision: persona.draft_revision
        )
      end
    end

    assert_equal "phrase_source_checksum_mismatch", error.code
    assert_empty persona.reload.draft_config.fetch("phrases")
    assert_empty persona.phrase_promotions
  end

  test "manual and setup updates cannot mint or edit approved-source artifacts but editors may remove them" do
    persona, promotion = promoted_persona
    changed = persona.draft_config.deep_dup
    changed.fetch("phrases").first["text"] = "Changed"

    error = assert_raises(Mia::PersonaDraftUpdater::Error) do
      Mia::PersonaDraftUpdater.new(persona: persona, actor: @editor, workspace: @workspace).call!(
        expected_draft_revision: persona.draft_revision,
        description: persona.description,
        draft_config: changed
      )
    end
    assert_equal "persona_invalid", error.code

    removed = persona.draft_config.deep_dup
    removed["phrases"] = []
    Mia::PersonaDraftUpdater.new(persona: persona, actor: @editor, workspace: @workspace).call!(
      expected_draft_revision: persona.reload.draft_revision,
      description: persona.description,
      draft_config: removed
    )
    assert_empty persona.reload.draft_config.fetch("phrases")

    Mia::PersonaPhrasePromoter.new(actor: @reviewer, workspace: @workspace).restore!(
      persona_id: persona.id,
      promotion_id: promotion.id,
      expected_draft_revision: persona.draft_revision
    )
    assert_equal promotion.artifact, persona.reload.draft_config.fetch("phrases").sole
  end

  test "promote replay succeeds with a stale revision only while its exact artifact is active" do
    persona, promotion = promoted_persona
    stale_revision = persona.draft_revision - 1

    replay = Mia::PersonaPhrasePromoter.new(actor: @reviewer, workspace: @workspace).promote!(
      persona_id: persona.id,
      proposal_id: promotion.coach_phrase_proposal_id,
      expected_draft_revision: stale_revision
    )
    assert_equal promotion.id, replay.id
    assert_equal persona.draft_revision, persona.reload.draft_revision

    remove_approved_phrase(persona)
    error = assert_raises(Mia::PersonaPhrasePromoter::Error) do
      Mia::PersonaPhrasePromoter.new(actor: @reviewer, workspace: @workspace).promote!(
        persona_id: persona.id,
        proposal_id: promotion.coach_phrase_proposal_id,
        expected_draft_revision: stale_revision
      )
    end
    assert_equal "persona_draft_conflict", error.code
  end

  test "restore replay succeeds with its stale request revision but inactive restore does not" do
    persona, promotion = promoted_persona
    remove_approved_phrase(persona)
    stale_inactive_revision = persona.draft_revision - 1
    promoter = Mia::PersonaPhrasePromoter.new(actor: @reviewer, workspace: @workspace)
    inactive_error = assert_raises(Mia::PersonaPhrasePromoter::Error) do
      promoter.restore!(
        persona_id: persona.id,
        promotion_id: promotion.id,
        expected_draft_revision: stale_inactive_revision
      )
    end
    assert_equal "persona_draft_conflict", inactive_error.code

    request_revision = persona.reload.draft_revision
    restored = promoter.restore!(
      persona_id: persona.id,
      promotion_id: promotion.id,
      expected_draft_revision: request_revision
    )
    replay = promoter.restore!(
      persona_id: persona.id,
      promotion_id: promotion.id,
      expected_draft_revision: request_revision
    )
    assert_equal restored.id, replay.id
    assert_equal request_revision + 1, persona.reload.draft_revision
  end

  test "prepared setup preserves participant artifacts while allowing approved-source removal" do
    persona, = promoted_persona
    participant = persona_phrase_artifact(
      { "text" => "My family calls it the storm fund." },
      source_user_id: persona_user(role: "participant").id,
      provenance: "participant_supplied"
    )
    with_participant = persona.draft_config.deep_dup
    with_participant["phrases"] << participant
    persona.update!(draft_config: with_participant)

    missing_participant = persona.draft_config.deep_dup
    missing_participant["phrases"].reject! { |phrase| phrase["provenance"] == "participant_supplied" }
    error = assert_raises(Mia::PersonaDraftUpdater::Error) do
      Mia::PersonaDraftUpdater.new(persona: persona, actor: @editor, workspace: @workspace).call!(
        expected_draft_revision: persona.draft_revision,
        description: persona.description,
        draft_config: missing_participant,
        prepared: true
      )
    end
    assert_equal "persona_setup_phrase_locked", error.code

    without_approved = persona.reload.draft_config.deep_dup
    without_approved["phrases"].reject! { |phrase| phrase["provenance"] == "approved_source" }
    Mia::PersonaDraftUpdater.new(persona: persona, actor: @editor, workspace: @workspace).call!(
      expected_draft_revision: persona.draft_revision,
      description: persona.description,
      draft_config: without_approved,
      prepared: true
    )
    assert_equal [ participant ], persona.reload.draft_config.fetch("phrases")
  end

  test "publish rollback and runtime bind approved phrases to immutable phrase manifests" do
    persona, promotion = promoted_persona
    version = publish_persona(persona, actor: @reviewer)

    assert version.phrase_manifest_valid?
    assert_equal promotion.id, version.phrase_artifact_links.sole.coach_persona_phrase_promotion_id
    assert_equal "approved_source", Mia::RuntimePersona.new(version).all_cultural_phrases.sole.fetch("provenance")

    version.phrase_artifact_links.sole.update_column(:promotion_digest, "0" * 64)
    refute version.reload.phrase_manifest_valid?
    assert_raises(Mia::PersonaSchema::InvalidConfiguration) { Mia::RuntimePersona.new(version) }
  end

  test "studio serialization fails closed when a draft promotion audit chain is corrupted" do
    persona, promotion = promoted_persona
    policy = Mia::PersonaStudioPolicy.new(@owner, workspace: @workspace)
    promotion.update_column(:promotion_digest, "0" * 64)

    detail = Mia::PersonaStudioSerializer.new(persona.reload, policy: policy).detail

    assert_equal true, detail.fetch(:preview_required)
    assert_equal true, detail.fetch(:has_unpublished_changes)
  end

  test "rollback copies phrase links and restores the reviewed draft selection" do
    persona, promotion = promoted_persona
    source_version = publish_persona(persona, actor: @reviewer)
    config = persona.draft_config.deep_dup
    config["phrases"] = []
    Mia::PersonaDraftUpdater.new(persona: persona, actor: @editor, workspace: @workspace).call!(
      expected_draft_revision: persona.draft_revision,
      description: persona.description,
      draft_config: config
    )
    without_phrase = publish_persona(persona.reload, actor: @reviewer)

    rolled_back = Mia::PersonaRollback.new(persona: persona, target_version: source_version, actor: @reviewer).call(
      expected_current_version_id: without_phrase.id,
      expected_draft_revision: persona.reload.draft_revision
    )

    assert rolled_back.phrase_manifest_valid?
    assert_equal promotion.id, rolled_back.phrase_artifact_links.sole.coach_persona_phrase_promotion_id
    assert_equal promotion.artifact, persona.reload.draft_config.fetch("phrases").sole
    assert_equal rolled_back.id, persona.current_published_version_id
  end

  test "source deletion supersedes only unattested proposals and keeps approved audit chains" do
    draft = with_source_download(@source_text) { create_proposal }
    submitted = with_source_download(@source_text) { create_proposal(@payload.merge("caution" => "Second proposal.")) }
    submitted = with_source_download(@source_text) do
      writer.submit!(proposal_id: submitted.id, expected_revision: submitted.revision, expected_digest: submitted.proposal_digest)
    end
    approved = with_source_download(@source_text) { create_proposal(@payload.merge("caution" => "Approved proposal.")) }
    approved = with_source_download(@source_text) do
      writer.submit!(proposal_id: approved.id, expected_revision: approved.revision, expected_digest: approved.proposal_digest)
    end
    with_source_download(@source_text) do
      Mia::PhraseAttester.new(actor: @reviewer, workspace: @workspace).call!(
        proposal_id: approved.id, decision: "approved", expected_digest: approved.proposal_digest
      )
    end

    submitted_at = submitted.submitted_at
    CoachPhraseProposal.supersede_open_for_source!(@source)

    assert_equal "superseded", draft.reload.status
    assert_nil draft.submitted_at
    assert_equal "superseded", submitted.reload.status
    assert_equal submitted_at, submitted.submitted_at
    assert_equal "submitted", approved.reload.status
    assert approved.attestation.integrity_valid?
  end

  test "proposal audit records cannot be destroyed before or after supersession" do
    proposal = with_source_download(@source_text) { create_proposal }
    assert_raises(ActiveRecord::RecordNotDestroyed) { proposal.destroy! }

    CoachPhraseProposal.supersede_open_for_source!(@source)
    assert_equal "superseded", proposal.reload.status
    assert_nil proposal.submitted_at
    assert_raises(ActiveRecord::RecordNotDestroyed) { proposal.destroy! }
  end

  test "submitted evidence and all sealed audit records reject direct persistence changes" do
    persona, promotion = promoted_persona
    proposal = promotion.coach_phrase_proposal
    attestation = promotion.coach_phrase_attestation
    version = publish_persona(persona, actor: @reviewer)
    link = version.phrase_artifact_links.sole

    assert_not proposal.update(phrase_payload: proposal.phrase_payload.merge("meaning" => "Changed"))
    assert proposal.errors.full_messages.any? { |message| message.include?("submitted phrase proposal evidence is immutable") }
    proposal.reload
    assert_not proposal.update(revision: proposal.revision + 1)
    assert proposal.errors.full_messages.any? { |message| message.include?("submitted phrase proposal evidence is immutable") }
    proposal.reload
    assert_not proposal.update(status: "draft", submitted_at: nil)
    assert proposal.errors.full_messages.any? { |message| message.include?("cannot move backward in the phrase review lifecycle") }

    assert_not attestation.update(decision: "rejected")
    assert attestation.errors.full_messages.any? { |message| message.include?("phrase attestations are immutable") }
    assert_raises(ActiveRecord::DeleteRestrictionError) { attestation.reload.destroy! }

    assert_not promotion.update(promoted_at: 1.minute.from_now)
    assert promotion.errors.full_messages.any? { |message| message.include?("phrase promotions are immutable") }
    assert_raises(ActiveRecord::DeleteRestrictionError) { promotion.reload.destroy! }

    assert_not link.update(position: link.position + 1)
    assert link.errors.full_messages.any? { |message| message.include?("published phrase artifact links are immutable") }
    assert_raises(ActiveRecord::RecordNotDestroyed) { link.reload.destroy! }
  end

  test "direct proposal field tampering invalidates every downstream integrity layer" do
    persona, promotion = promoted_persona
    version = publish_persona(persona, actor: @reviewer)
    proposal = promotion.coach_phrase_proposal
    original_proposer_id = proposal.proposed_by_user_id

    proposal.update_column(:proposed_by_user_id, @owner.id)
    assert_broken_phrase_chain(proposal.reload, promotion.reload, version.reload)

    proposal.update_column(:proposed_by_user_id, original_proposer_id)
    assert proposal.reload.integrity_valid?
    proposal.update_column(:evidence_end_byte, proposal.evidence_end_byte + 1)
    assert_broken_phrase_chain(proposal.reload, promotion.reload, version.reload)
  end

  test "solo owner self-review is explicit and disabled when another reviewer exists" do
    proposal = with_source_download(@source_text) do
      Mia::PhraseProposalWriter.new(actor: @owner, workspace: @workspace).create!(
        source_id: @source.id,
        candidate_id: @candidate.id,
        content_item_version_id: @version.id,
        phrase_payload: @payload
      )
    end
    proposal = with_source_download(@source_text) do
      Mia::PhraseProposalWriter.new(actor: @owner, workspace: @workspace).submit!(
        proposal_id: proposal.id, expected_revision: proposal.revision, expected_digest: proposal.proposal_digest
      )
    end
    error = assert_raises(Mia::PhraseAttester::Error) do
      Mia::PhraseAttester.new(actor: @owner, workspace: @workspace).call!(
        proposal_id: proposal.id, decision: "approved", expected_digest: proposal.proposal_digest
      )
    end
    assert_equal "phrase_self_review_not_allowed", error.code

    @workspace.coach_workspace_memberships.find_by!(user: @reviewer).destroy!
    with_source_download(@source_text) do
      attestation = Mia::PhraseAttester.new(actor: @owner, workspace: @workspace).call!(
        proposal_id: proposal.id, decision: "approved", expected_digest: proposal.proposal_digest
      )
      assert attestation.self_review
    end
  end

  test "new packs reject phrase items while retrieval ignores a legacy sealed phrase entry" do
    pack = CoachContentPack.create!(
      name: "No phrase pack", description: "Compatibility", scope: "coach",
      pack_kind: "voice_culture", created_by_user: @owner, coach_workspace: @workspace
    )
    error = assert_raises(ArgumentError) do
      pack.replace_draft_item_versions!([ @version ], actor: @owner)
    end
    assert_match(/promoted through approved phrase review/, error.message)

    legacy = pack.versions.create!(
      version_number: 1, name: pack.name, description: pack.description, scope: pack.scope,
      pack_kind: pack.pack_kind, content_digest: "0" * 64, published_by_user: @owner
    )
    legacy.entries.create!(coach_content_item_version: @version, position: 0)
    legacy.seal!
    assert legacy.manifest_valid?
    assert_empty Mia::ApprovedContentRetriever.new(persona: nil, query: "Håfa adai", pack_versions: [ legacy ]).call
  end

  private

  def remove_approved_phrase(persona)
    config = persona.reload.draft_config.deep_dup
    config["phrases"].reject! { |phrase| phrase["provenance"] == "approved_source" }
    Mia::PersonaDraftUpdater.new(persona: persona, actor: @editor, workspace: @workspace).call!(
      expected_draft_revision: persona.draft_revision,
      description: persona.description,
      draft_config: config
    )
  end

  def assert_broken_phrase_chain(proposal, promotion, version)
    refute proposal.integrity_valid?
    refute proposal.attestation.reload.integrity_valid?
    refute promotion.integrity_valid?
    refute version.phrase_manifest_valid?
    assert_raises(Mia::PersonaSchema::InvalidConfiguration) { Mia::RuntimePersona.new(version) }
  end

  def writer
    @writer ||= Mia::PhraseProposalWriter.new(actor: @editor, workspace: @workspace)
  end

  def create_proposal(payload = @payload)
    writer.create!(
      source_id: @source.id,
      candidate_id: @candidate.id,
      content_item_version_id: @version.id,
      phrase_payload: payload
    )
  end

  def promoted_persona
    proposal = with_source_download(@source_text) { create_proposal(@payload.merge("caution" => SecureRandom.hex(4))) }
    proposal = with_source_download(@source_text) do
      writer.submit!(proposal_id: proposal.id, expected_revision: proposal.revision, expected_digest: proposal.proposal_digest)
    end
    with_source_download(@source_text) do
      Mia::PhraseAttester.new(actor: @reviewer, workspace: @workspace).call!(
        proposal_id: proposal.id, decision: "approved", expected_digest: proposal.proposal_digest
      )
    end
    persona = create_persona(creator: @owner, workspace: @workspace)
    promotion = with_source_download(@source_text) do
      Mia::PersonaPhrasePromoter.new(actor: @reviewer, workspace: @workspace).promote!(
        persona_id: persona.id, proposal_id: proposal.id, expected_draft_revision: persona.draft_revision
      )
    end
    [ persona.reload, promotion ]
  end

  def approved_phrase_source(owner:, source_text:, candidate_title: "Reviewed greeting", candidate_content: "Håfa adai")
    source = CoachContentSource.create!(
      scope: "coach", coach_workspace: @workspace, created_by_user: owner, status: "processing",
      filename: "coach-phrases.txt", content_type: "text/plain", byte_size: source_text.bytesize,
      checksum_sha256: Digest::SHA256.hexdigest(source_text.b), s3_key: "test/source/#{SecureRandom.uuid}",
      upload_request_id: SecureRandom.uuid, generation: 1
    )
    attempt = source.attempts.create!(
      generation: 1, provider: "openrouter", model: "test", prompt_version: "v1", schema_version: "v1",
      status: "succeeded", started_at: 1.minute.ago, completed_at: Time.current
    )
    source.update!(status: "needs_review", current_attempt: attempt, processed_at: Time.current)
    locator = {
      "type" => "text", "segment" => 1, "line_start" => 1, "line_end" => 1,
      "excerpt_digest" => Digest::SHA256.hexdigest("Håfa adai".b)
    }
    candidate = source.candidates.create!(
      coach_content_source_attempt: attempt, position: 0, status: "proposed", title: candidate_title,
      kind: "phrase", content: candidate_content, topics: [ "greeting" ], evidence_locator: locator,
      evidence_excerpt: "Håfa adai", content_digest: CoachContentSourceCandidate.digest_for(
        title: candidate_title, kind: "phrase", content: candidate_content, topics: [ "greeting" ]
      )
    )
    item = candidate.accept!(actor: owner, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    version = item.approve!(actor: owner, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    [ source.reload, candidate.reload, version ]
  end

  def with_source_download(content)
    original = S3Service.method(:download_to_io!)
    S3Service.define_singleton_method(:download_to_io!) do |_key, io|
      io.write(content)
      io.flush
      true
    end
    yield
  ensure
    S3Service.define_singleton_method(:download_to_io!, original)
  end
end
