# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CoachContentSourceTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "candidate acceptance creates only a coach-owned editable draft with immutable provenance" do
    coach = persona_user
    admin = persona_user(role: "admin")
    source, _attempt, candidate = source_candidate(owner: coach)

    item = candidate.accept!(actor: admin, expected_revision: candidate.revision, expected_digest: candidate.content_digest)

    assert_equal coach, item.created_by_user
    assert_equal "coach", item.scope
    refute item.draft_always_on
    assert_nil item.current_approved_version
    assert_equal candidate, item.draft_source_provenance.coach_content_source_candidate
    provenance = item.draft_source_provenance
    assert provenance.integrity_valid?
    assert_equal "accepted", provenance.candidate_review_action
    assert_equal admin, provenance.accepted_by_user
    assert_equal "accepted", candidate.reload.status
    assert_equal source.id, candidate.coach_content_source_id
  end

  test "candidate edits and acceptance use revision and digest CAS" do
    coach = persona_user
    _source, _attempt, candidate = source_candidate(owner: coach)
    stale_revision = candidate.revision
    stale_digest = candidate.content_digest
    original_proposal_digest = candidate.original_proposal_digest

    candidate.update_review!(
      { title: "Revised lesson", kind: "guidance", content: "Use the revised coaching lesson.", topics: [ "Routine" ] },
      actor: coach,
      expected_revision: stale_revision,
      expected_digest: stale_digest
    )

    assert_raises(CoachContentSourceCandidate::ReviewConflict) do
      candidate.accept!(actor: coach, expected_revision: stale_revision, expected_digest: stale_digest)
    end
    assert_equal original_proposal_digest, candidate.original_proposal_digest
    refute_equal original_proposal_digest, candidate.content_digest
    item = candidate.accept!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    assert_equal "Revised lesson", item.title
    assert_equal item, candidate.accept!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    draft_provenance = item.draft_source_provenance
    assert_equal original_proposal_digest, draft_provenance.candidate_original_proposal_digest
    assert_equal candidate.content_digest, draft_provenance.candidate_content_digest
    assert_equal candidate.revision, draft_provenance.candidate_revision
    assert_equal coach, draft_provenance.accepted_by_user
    assert_equal candidate.reviewed_at, draft_provenance.accepted_at
    assert_equal "accepted", draft_provenance.candidate_review_action

    version = item.approve!(actor: coach, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    version_provenance = version.source_provenance
    assert_equal original_proposal_digest, version_provenance.candidate_original_proposal_digest
    assert_equal candidate.content_digest, version_provenance.candidate_content_digest
    assert_equal candidate.revision, version_provenance.candidate_revision
    assert_equal coach, version_provenance.accepted_by_user
    assert_equal candidate.reviewed_at, version_provenance.accepted_at
    assert_equal "accepted", version_provenance.candidate_review_action
    assert version_provenance.integrity_valid?
  end

  test "candidate edits are rechecked and persist a recoverable safety state" do
    coach = persona_user
    _source, _attempt, candidate = source_candidate(owner: coach)
    error = assert_raises(Mia::ContentSafetyValidator::UnsafeContent) do
      candidate.update_review!(
        { title: "Private", kind: "guidance", content: "Contact jane@example.com for help.", topics: [] },
        actor: coach,
        expected_revision: candidate.revision,
        expected_digest: candidate.content_digest
      )
    end

    assert_equal "personal_information", error.code
    assert_equal "proposed", candidate.reload.status
    assert_equal "personal_information", candidate.safety_code
    assert_equal "Contact jane@example.com for help.", candidate.content
    assert_nil candidate.accepted_content_item

    assert_raises(Mia::ContentSafetyValidator::UnsafeContent) do
      candidate.accept!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    end

    candidate.update_review!(
      { title: "Private", kind: "guidance", content: "Review the general guidance together.", topics: [] },
      actor: coach,
      expected_revision: candidate.revision,
      expected_digest: candidate.content_digest
    )
    assert_nil candidate.reload.safety_code
  end

  test "source canary stays outside runtime until the exact persona is published" do
    coach = persona_user
    persona = create_persona(creator: coach, name: "Canary assistant")
    initial_version = publish_persona(persona, actor: coach)
    old_runtime = Mia::RuntimePersona.new(initial_version)
    source, attempt, candidate = source_candidate(
      owner: coach,
      title: "Opal compass protocol",
      content: "Use the opal compass protocol to choose one practical next step."
    )

    assert_runtime_excludes(old_runtime, "opal compass")
    assert_prompt_builders_exclude([], "opal compass")
    item = candidate.accept!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    assert_runtime_excludes(old_runtime, "opal compass")

    version = item.approve!(actor: coach, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    assert version.source_provenance.integrity_valid?
    assert_runtime_excludes(old_runtime, "opal compass")

    pack = CoachContentPack.create!(name: "Canary pack", scope: "coach", pack_kind: "coaching_method", created_by_user: coach)
    pack.replace_draft_item_versions!([ version ], actor: coach)
    pack_version = pack.publish!(
      actor: coach,
      expected_draft_revision: pack.draft_revision,
      expected_draft_manifest_digest: pack.draft_manifest_digest,
      expected_current_version_id: nil
    )
    assert pack_version.manifest_valid?
    assert_runtime_excludes(old_runtime, "opal compass")

    persona.replace_draft_content_pack_versions!([ pack_version ], actor: coach)
    assert_runtime_excludes(old_runtime, "opal compass")
    published = publish_persona(persona, actor: coach)
    results = Mia::ApprovedContentRetriever.new(persona: Mia::RuntimePersona.new(published), query: "opal compass").call
    assert_equal [ version.id ], results.map { |result| result.fetch(:item_version).id }
    assert_prompt_builders_include(results, "opal compass")
    assert_prompt_builders_exclude(results, "Coach-approved source evidence")

    original_checksum = source.checksum_sha256
    source.update_column(:checksum_sha256, "0" * 64)
    refute version.source_provenance.reload.integrity_valid?
    refute pack_version.reload.manifest_valid?
    source.update_column(:checksum_sha256, original_checksum)
    assert version.source_provenance.reload.integrity_valid?

    original_model = attempt.model
    attempt.update_column(:model, "tampered-model")
    refute version.source_provenance.reload.integrity_valid?
    attempt.update_column(:model, original_model)
    assert version.source_provenance.reload.integrity_valid?

    original_content = candidate.content
    candidate.update_column(:content, "Tampered candidate content")
    refute version.source_provenance.reload.integrity_valid?
    candidate.update_column(:content, original_content)
    assert version.source_provenance.reload.integrity_valid?

    original_locator = candidate.evidence_locator
    candidate.update_column(:evidence_locator, original_locator.merge("line_start" => 99))
    refute version.source_provenance.reload.integrity_valid?
    candidate.update_column(:evidence_locator, original_locator)
    assert version.source_provenance.reload.integrity_valid?

    original_proposal_digest = candidate.original_proposal_digest
    candidate.update_column(:original_proposal_digest, "0" * 64)
    refute version.source_provenance.reload.integrity_valid?
    candidate.update_column(:original_proposal_digest, original_proposal_digest)
    assert version.source_provenance.reload.integrity_valid?

    original_revision = candidate.revision
    candidate.update_column(:revision, original_revision + 1)
    refute version.source_provenance.reload.integrity_valid?
    candidate.update_column(:revision, original_revision)
    assert version.source_provenance.reload.integrity_valid?

    original_reviewer_id = candidate.reviewed_by_user_id
    other_reviewer = persona_user
    candidate.update_column(:reviewed_by_user_id, other_reviewer.id)
    refute version.source_provenance.reload.integrity_valid?
    candidate.update_column(:reviewed_by_user_id, original_reviewer_id)
    assert version.source_provenance.reload.integrity_valid?

    original_reviewed_at = candidate.reviewed_at
    candidate.update_column(:reviewed_at, original_reviewed_at + 1.second)
    refute version.source_provenance.reload.integrity_valid?
    candidate.update_column(:reviewed_at, original_reviewed_at)
    assert version.source_provenance.reload.integrity_valid?

    candidate.update_column(:status, "rejected")
    refute version.source_provenance.reload.integrity_valid?
    refute pack_version.reload.manifest_valid?
    assert_empty Mia::ApprovedContentRetriever.new(persona: Mia::RuntimePersona.new(published.reload), query: "opal compass").call
    candidate.update_column(:status, "accepted")
    assert version.source_provenance.reload.integrity_valid?
    version.source_provenance.candidate_review_action = "rejected"
    refute version.source_provenance.integrity_valid?
    version.source_provenance.reload

    other_coach = persona_user
    item.update_column(:created_by_user_id, other_coach.id)
    refute version.source_provenance.reload.integrity_valid?
    item.update_column(:created_by_user_id, coach.id)
    assert version.source_provenance.reload.integrity_valid?

    source.update_column(:checksum_sha256, "0" * 64)
    refute pack_version.reload.manifest_valid?
    assert_empty Mia::ApprovedContentRetriever.new(persona: Mia::RuntimePersona.new(published.reload), query: "opal compass").call
    assert_equal source.id, version.source_provenance.coach_content_source_id
  end

  test "source-derived manual approval is safety checked" do
    coach = persona_user
    _source, _attempt, candidate = source_candidate(owner: coach)
    item = candidate.accept!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    item.update!(draft_content: "Our debt balance is $44,321")

    assert_raises(Mia::ContentSafetyValidator::UnsafeContent) do
      item.approve!(actor: coach, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    end
    assert_nil item.reload.current_approved_version
  end

  test "ordinary manual budget and IRS guidance remains approvable" do
    coach = persona_user
    item = CoachContentItem.create!(
      title: "Routine references", scope: "coach", kind: "guidance",
      draft_content: "Update your household budget after reviewing the bill. Review current IRS guidance with a qualified professional.",
      draft_always_on: false, created_by_user: coach
    )

    version = item.approve!(actor: coach, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)

    assert_equal item.id, version.coach_content_item_id
    assert version.integrity_valid?
  end

  test "queued reprocessing makes prior generation candidates unreviewable" do
    coach = persona_user
    source, _attempt, candidate = source_candidate(owner: coach)
    source.update!(status: "queued")

    assert_raises(ArgumentError) do
      candidate.update_review!(
        { title: "Stale edit" }, actor: coach,
        expected_revision: candidate.revision, expected_digest: candidate.content_digest
      )
    end
    assert_raises(ArgumentError) do
      candidate.reject!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    end
    assert_equal "proposed", candidate.reload.status
    assert_equal "One clear move", candidate.title
  end

  test "retrieving a thirty-item sourced pack uses bounded queries" do
    coach = persona_user
    persona = create_persona(creator: coach, name: "Scale assistant")
    source, attempt, first_candidate = source_candidate(owner: coach, title: "Scale lesson 0", content: "Scale canary 0 offers one general step.")
    candidates = [ first_candidate ]
    1.upto(29) do |index|
      title = "Scale lesson #{index}"
      content = index == 29 ? "Ultraviolet scale canary offers one general step." : "Scale canary #{index} offers one general step."
      candidates << source.candidates.create!(
        coach_content_source_attempt: attempt, position: index, status: "proposed", title: title, kind: "guidance",
        content: content, topics: [ "scale" ],
        evidence_locator: { "type" => "text", "segment" => 1, "line_start" => index + 1, "line_end" => index + 1, "excerpt_digest" => Digest::SHA256.hexdigest("evidence-#{index}") },
        evidence_excerpt: "General scale evidence #{index}.",
        content_digest: CoachContentSourceCandidate.digest_for(title: title, kind: "guidance", content: content, topics: [ "scale" ])
      )
    end
    versions = candidates.map do |candidate|
      item = candidate.accept!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
      item.approve!(actor: coach, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    end
    pack = CoachContentPack.create!(name: "Scale pack", scope: "coach", pack_kind: "coaching_method", created_by_user: coach)
    pack.replace_draft_item_versions!(versions, actor: coach)
    pack_version = pack.publish!(
      actor: coach, expected_draft_revision: pack.draft_revision,
      expected_draft_manifest_digest: pack.draft_manifest_digest, expected_current_version_id: nil
    )
    persona.replace_draft_content_pack_versions!([ pack_version ], actor: coach)
    published = publish_persona(persona, actor: coach)
    runtime = Mia::RuntimePersona.new(published.reload)

    queries = 0
    query_lines = []
    callback = lambda do |*, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]
      if payload[:sql].match?(/SELECT.+coach_(?:content|persona)/m)
        queries += 1
        query_lines << "#{payload[:name]}: #{payload[:sql].squish}"
      end
    end
    results = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      results = Mia::ApprovedContentRetriever.new(persona: runtime, query: "ultraviolet scale").call
    end

    assert_operator queries, :<=, 12, query_lines.join("\n")
    assert_equal versions.last.id, results.first.fetch(:item_version).id
  end

  private

  def source_candidate(owner:, title: "One clear move", content: "Choose one clear coaching move and review it together.")
    source = CoachContentSource.create!(
      scope: owner.admin? ? "platform" : "coach",
      created_by_user: owner,
      status: "processing",
      filename: "coach-guide.txt",
      content_type: "text/plain",
      byte_size: 120,
      checksum_sha256: Digest::SHA256.hexdigest("source"),
      s3_key: "test/content-source/#{SecureRandom.uuid}",
      upload_request_id: SecureRandom.uuid,
      generation: 1
    )
    attempt = source.attempts.create!(
      generation: 1,
      provider: "openrouter",
      model: "test-model",
      prompt_version: ContentSources::CandidateProposer::PROMPT_VERSION,
      schema_version: ContentSources::CandidateProposer::SCHEMA_VERSION,
      status: "succeeded",
      started_at: 1.minute.ago,
      completed_at: Time.current
    )
    source.update!(status: "needs_review", current_attempt: attempt, processed_at: Time.current)
    digest = CoachContentSourceCandidate.digest_for(title: title, kind: "guidance", content: content, topics: [ "planning" ])
    candidate = source.candidates.create!(
      coach_content_source_attempt: attempt,
      position: 0,
      status: "proposed",
      title: title,
      kind: "guidance",
      content: content,
      topics: [ "planning" ],
      evidence_locator: {
        "type" => "text",
        "segment" => 1,
        "line_start" => 1,
        "line_end" => 2,
        "excerpt_digest" => Digest::SHA256.hexdigest("evidence")
      },
      evidence_excerpt: "Coach-approved source evidence.",
      content_digest: digest,
      revision: 1
    )
    [ source, attempt, candidate ]
  end

  def assert_runtime_excludes(runtime, query)
    assert_empty Mia::ApprovedContentRetriever.new(persona: runtime, query: query).call
  end

  def assert_prompt_builders_exclude(approved_content, phrase)
    refute_includes prompt_builder_text(approved_content), phrase
  end

  def assert_prompt_builders_include(approved_content, phrase)
    assert_includes prompt_builder_text(approved_content), phrase
  end

  def prompt_builder_text(approved_content)
    responder = Demo::MiaResponder.new(approved_content: approved_content)
    narrator = HouseholdFinance::MiaNarrator.new(
      user_message: "What is one next step?",
      answer_packet: { fallback_response: "Choose one practical next step.", write_state: "no_write" },
      approved_content: approved_content
    )
    JSON.generate(responder.send(:approved_content_messages)) + JSON.generate(narrator.send(:approved_content_prompt))
  end
end
