# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminApprovedPhrasePromotionsControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include ActiveJob::TestHelper

  setup do
    @owner = persona_user
    @workspace = CoachWorkspaces::Resolver.new(user: @owner).call
    @editor = persona_user
    @reviewer = persona_user
    @viewer = persona_user
    @workspace.coach_workspace_memberships.create!(user: @editor, role: "editor")
    @workspace.coach_workspace_memberships.create!(user: @reviewer, role: "reviewer")
    @workspace.coach_workspace_memberships.create!(user: @viewer, role: "viewer")
    @source_text = "Håfa adai. Keep one practical next step."
    @source, @candidate, @version = approved_phrase_source
    @phrase = {
      text: "Håfa adai", meaning: "A reviewed greeting.", allowed_contexts: [ "greeting" ],
      prohibited_contexts: [ "crisis" ], frequency: "rare", caution: "Use only as a greeting."
    }
  end

  test "narrow endpoints create submit attest promote and serialize no raw source evidence" do
    get "/api/v1/admin/content_sources/#{@source.id}", headers: workspace_headers(@editor)
    assert_response :success
    assert_equal @version.id, response.parsed_body.dig("source", "candidates", 0, "accepted_content_item_version_id")
    assert_equal @version.kind, response.parsed_body.dig("source", "candidates", 0, "accepted_content_item_version_kind")
    assert_equal @version.content, response.parsed_body.dig("source", "candidates", 0, "accepted_content_item_version_content")

    get "/api/v1/admin/content_sources/#{@source.id}/phrase_proposals", headers: workspace_headers(@editor)
    assert_response :success
    assert_empty response.parsed_body.fetch("phrase_proposals")
    assert_equal true, response.parsed_body.dig("permissions", "propose")

    with_source_download do
      post "/api/v1/admin/content_sources/#{@source.id}/phrase_proposals", params: {
        phrase_proposal: {
          candidate_id: @candidate.id,
          content_item_version_id: @version.id,
          phrase: @phrase.merge(source_checksum_sha256: "0" * 64, evidence_locator: { private: true })
        }
      }, headers: workspace_headers(@editor), as: :json
    end
    assert_response :created
    proposal_json = response.parsed_body.fetch("phrase_proposal")
    proposal = CoachPhraseProposal.find(proposal_json.fetch("id"))
    assert_equal @phrase.stringify_keys, proposal.phrase_payload
    refute_includes response.body, proposal.source_checksum_sha256
    refute_includes response.body, "evidence_locator"

    get "/api/v1/admin/content_sources/#{@source.id}/phrase_proposals", headers: workspace_headers(@editor)
    assert_response :success
    assert_equal proposal.id, response.parsed_body.dig("phrase_proposals", 0, "id")

    with_source_download do
      post "/api/v1/admin/phrase_proposals/#{proposal.id}/submit", params: {
        phrase_proposal: { revision: proposal.revision, digest: proposal.proposal_digest }
      }, headers: workspace_headers(@editor), as: :json
    end
    assert_response :success
    proposal.reload

    with_source_download do
      post "/api/v1/admin/phrase_proposals/#{proposal.id}/attestation", params: {
        attestation: { decision: "approved", proposal_digest: proposal.proposal_digest, phrase: "ignored" }
      }, headers: workspace_headers(@reviewer), as: :json
    end
    assert_response :success

    persona = create_persona(creator: @owner, workspace: @workspace)
    with_source_download do
      post "/api/v1/admin/personas/#{persona.id}/phrase_promotions", params: {
        phrase_promotion: { proposal_id: proposal.id, draft_revision: persona.draft_revision, artifact: { forged: true } }
      }, headers: workspace_headers(@reviewer), as: :json
    end
    assert_response :created
    assert_equal "approved_source", response.parsed_body.dig("persona", "draft", "phrases", 0, "provenance")
    assert_equal "Approved private source", response.parsed_body.dig("persona", "phrase_artifact_access", "artifacts", 0, "source_label")

    get "/api/v1/admin/phrase_proposals/#{proposal.id}", headers: workspace_headers(@viewer)
    assert_response :success
    refute_includes response.body, proposal.source_checksum_sha256
    refute_includes response.body, @source.filename
  end

  test "source candidate serialization exposes the locked reviewed phrase version" do
    get "/api/v1/admin/content_sources/#{@source.id}", headers: workspace_headers(@editor)
    assert_response :success
    candidate = response.parsed_body.dig("source", "candidates", 0)
    assert_equal @version.id, candidate.fetch("accepted_content_item_version_id")
    assert_equal "phrase", candidate.fetch("accepted_content_item_version_kind")
    assert_equal candidate.fetch("content"), candidate.fetch("accepted_content_item_version_content")
  end

  test "identical create retry returns the proposal from the lost response" do
    request = {
      phrase_proposal: {
        candidate_id: @candidate.id,
        content_item_version_id: @version.id,
        phrase: @phrase
      }
    }
    with_source_download do
      post "/api/v1/admin/content_sources/#{@source.id}/phrase_proposals",
        params: request, headers: workspace_headers(@editor), as: :json
    end
    assert_response :created
    proposal_id = response.parsed_body.dig("phrase_proposal", "id")

    with_source_download do
      post "/api/v1/admin/content_sources/#{@source.id}/phrase_proposals",
        params: request, headers: workspace_headers(@editor), as: :json
    end
    assert_response :created
    assert_equal proposal_id, response.parsed_body.dig("phrase_proposal", "id")
    assert_equal 1, CoachPhraseProposal.where(id: proposal_id).count
  end

  test "malformed phrase collection payloads return a safe validation error" do
    with_source_download do
      post "/api/v1/admin/content_sources/#{@source.id}/phrase_proposals", params: {
        phrase_proposal: {
          candidate_id: @candidate.id,
          content_item_version_id: @version.id,
          phrase: []
        }
      }, headers: workspace_headers(@editor), as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "phrase_payload_invalid", response.parsed_body.fetch("code")

    proposal = with_source_download do
      Mia::PhraseProposalWriter.new(actor: @editor, workspace: @workspace).create!(
        source_id: @source.id,
        candidate_id: @candidate.id,
        content_item_version_id: @version.id,
        phrase_payload: @phrase
      )
    end
    with_source_download do
      patch "/api/v1/admin/phrase_proposals/#{proposal.id}", params: {
        phrase_proposal: {
          revision: proposal.revision,
          digest: proposal.proposal_digest,
          phrase: []
        }
      }, headers: workspace_headers(@editor), as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "phrase_payload_invalid", response.parsed_body.fetch("code")
    assert_equal "draft", proposal.reload.status
  end

  test "selected workspace is mandatory and tenant boundaries conceal records" do
    proposal = with_source_download do
      Mia::PhraseProposalWriter.new(actor: @editor, workspace: @workspace).create!(
        source_id: @source.id, candidate_id: @candidate.id,
        content_item_version_id: @version.id, phrase_payload: @phrase
      )
    end
    admin = persona_user(role: "admin")
    get "/api/v1/admin/phrase_proposals/#{proposal.id}", headers: auth_headers(admin)
    assert_response :unprocessable_entity
    assert_equal "coach_workspace_required", response.parsed_body.fetch("code")

    other_owner = persona_user
    other_workspace = CoachWorkspaces::Resolver.new(user: other_owner).call
    get "/api/v1/admin/phrase_proposals/#{proposal.id}", headers: workspace_headers(other_owner, other_workspace)
    assert_response :not_found
  end

  test "role boundaries keep editors from attesting and reviewers from proposing" do
    post "/api/v1/admin/content_sources/#{@source.id}/phrase_proposals", params: {
      phrase_proposal: { candidate_id: @candidate.id, content_item_version_id: @version.id, phrase: @phrase }
    }, headers: workspace_headers(@reviewer), as: :json
    assert_response :unprocessable_entity
    assert_equal "phrase_proposal_forbidden", response.parsed_body.fetch("code")

    proposal = with_source_download do
      writer = Mia::PhraseProposalWriter.new(actor: @editor, workspace: @workspace)
      draft = writer.create!(source_id: @source.id, candidate_id: @candidate.id, content_item_version_id: @version.id, phrase_payload: @phrase)
      writer.submit!(proposal_id: draft.id, expected_revision: draft.revision, expected_digest: draft.proposal_digest)
    end
    post "/api/v1/admin/phrase_proposals/#{proposal.id}/attestation", params: {
      attestation: { decision: "approved", proposal_digest: proposal.proposal_digest }
    }, headers: workspace_headers(@editor), as: :json
    assert_response :not_found
  end

  test "another editor can view a draft but cannot edit or submit the proposer's record" do
    other_editor = persona_user
    @workspace.coach_workspace_memberships.create!(user: other_editor, role: "editor")
    proposal = with_source_download do
      Mia::PhraseProposalWriter.new(actor: @editor, workspace: @workspace).create!(
        source_id: @source.id,
        candidate_id: @candidate.id,
        content_item_version_id: @version.id,
        phrase_payload: @phrase
      )
    end

    get "/api/v1/admin/phrase_proposals/#{proposal.id}", headers: workspace_headers(other_editor)
    assert_response :success
    assert_equal false, response.parsed_body.dig("phrase_proposal", "permissions", "edit")
    assert_equal false, response.parsed_body.dig("phrase_proposal", "permissions", "submit")

    patch "/api/v1/admin/phrase_proposals/#{proposal.id}", params: {
      phrase_proposal: {
        revision: proposal.revision,
        digest: proposal.proposal_digest,
        phrase: @phrase.merge(caution: "Other editor change")
      }
    }, headers: workspace_headers(other_editor), as: :json
    assert_response :not_found
    assert_equal "phrase_proposal_not_found", response.parsed_body.fetch("code")

    post "/api/v1/admin/phrase_proposals/#{proposal.id}/submit", params: {
      phrase_proposal: { revision: proposal.revision, digest: proposal.proposal_digest }
    }, headers: workspace_headers(other_editor), as: :json
    assert_response :not_found
    assert_equal "phrase_proposal_not_found", response.parsed_body.fetch("code")
  end

  test "an owner cannot review their own submitted proposal while another reviewer is available" do
    writer = Mia::PhraseProposalWriter.new(actor: @owner, workspace: @workspace)
    proposal = with_source_download do
      draft = writer.create!(
        source_id: @source.id,
        candidate_id: @candidate.id,
        content_item_version_id: @version.id,
        phrase_payload: @phrase.merge(caution: "Owner proposal requiring independent review.")
      )
      writer.submit!(proposal_id: draft.id, expected_revision: draft.revision, expected_digest: draft.proposal_digest)
    end

    get "/api/v1/admin/phrase_proposals/#{proposal.id}", headers: workspace_headers(@owner)
    assert_response :success
    assert_equal false, response.parsed_body.dig("phrase_proposal", "permissions", "review")

    get "/api/v1/admin/phrase_proposals/#{proposal.id}", headers: workspace_headers(@reviewer)
    assert_response :success
    assert_equal true, response.parsed_body.dig("phrase_proposal", "permissions", "review")

    with_source_download do
      post "/api/v1/admin/phrase_proposals/#{proposal.id}/attestation", params: {
        attestation: { decision: "approved", proposal_digest: proposal.proposal_digest }
      }, headers: workspace_headers(@owner), as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "phrase_self_review_not_allowed", response.parsed_body.fetch("code")
  end

  test "source deletion request supersedes an open phrase proposal before storage cleanup" do
    proposal = with_source_download do
      Mia::PhraseProposalWriter.new(actor: @editor, workspace: @workspace).create!(
        source_id: @source.id, candidate_id: @candidate.id,
        content_item_version_id: @version.id, phrase_payload: @phrase
      )
    end

    assert_enqueued_with(job: CoachContentSourceDeletionJob) do
      delete "/api/v1/admin/content_sources/#{@source.id}/source", headers: workspace_headers(@editor)
    end

    assert_response :accepted
    assert_equal "superseded", proposal.reload.status
    assert_equal "deletion_pending", @source.reload.status
  end

  private

  def approved_phrase_source
    source = CoachContentSource.create!(
      scope: "coach", coach_workspace: @workspace, created_by_user: @owner, status: "processing",
      filename: "coach-phrases.txt", content_type: "text/plain", byte_size: @source_text.bytesize,
      checksum_sha256: Digest::SHA256.hexdigest(@source_text.b), s3_key: "test/source/#{SecureRandom.uuid}",
      upload_request_id: SecureRandom.uuid, generation: 1
    )
    attempt = source.attempts.create!(
      generation: 1, provider: "openrouter", model: "test", prompt_version: "v1", schema_version: "v1",
      status: "succeeded", started_at: 1.minute.ago, completed_at: Time.current
    )
    source.update!(status: "needs_review", current_attempt: attempt, processed_at: Time.current)
    candidate = source.candidates.create!(
      coach_content_source_attempt: attempt, position: 0, status: "proposed", title: "Reviewed greeting",
      kind: "phrase", content: "Håfa adai", topics: [ "greeting" ],
      evidence_locator: {
        "type" => "text", "segment" => 1, "line_start" => 1, "line_end" => 1,
        "excerpt_digest" => Digest::SHA256.hexdigest("Håfa adai".b)
      },
      evidence_excerpt: "Håfa adai", content_digest: CoachContentSourceCandidate.digest_for(
        title: "Reviewed greeting", kind: "phrase", content: "Håfa adai", topics: [ "greeting" ]
      )
    )
    item = candidate.accept!(actor: @owner, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    version = item.approve!(actor: @owner, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    [ source.reload, candidate.reload, version ]
  end

  def with_source_download
    original = S3Service.method(:download_to_io!)
    content = @source_text
    S3Service.define_singleton_method(:download_to_io!) { |_key, io| io.write(content); io.flush; true }
    yield
  ensure
    S3Service.define_singleton_method(:download_to_io!, original)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def workspace_headers(user, workspace = @workspace)
    auth_headers(user).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
  end
end
