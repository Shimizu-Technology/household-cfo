# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaApprovedSourcePhraseLockingTest < ActiveSupport::TestCase
  include PersonaTestHelper

  self.use_transactional_tests = false

  test "current phrase item approval replay waits until proposal evidence is sealed" do
    owner = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: owner).call
    editor = persona_user
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    source_text = "Håfa adai. Keep one practical next step."
    source, candidate, version = approved_phrase_source(owner:, workspace:, source_text:)
    item = version.coach_content_item
    remember_records(owner:, editor:, workspace:, source:, item:)

    verifier_entered = Queue.new
    release_verifier = Queue.new
    writer_result = Queue.new
    original_download = S3Service.method(:download_to_io!)
    S3Service.define_singleton_method(:download_to_io!) do |_key, io|
      io.write(source_text)
      io.flush
      verifier_entered << true
      release_verifier.pop
      true
    end

    writer_thread = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do
        begin
          proposal = Mia::PhraseProposalWriter.new(
            actor: User.find(editor.id),
            workspace: CoachWorkspace.find(workspace.id)
          ).create!(
            source_id: source.id,
            candidate_id: candidate.id,
            content_item_version_id: version.id,
            phrase_payload: phrase_payload
          )
          writer_result << proposal.id
        rescue StandardError => error
          writer_result << error
        end
      end
    end
    verifier_entered.pop

    connection = ActiveRecord::Base.connection
    connection.execute("SET lock_timeout = '500ms'")
    locked_item = CoachContentItem.find(item.id)
    assert_raises ActiveRecord::LockWaitTimeout do
      locked_item.approve!(
        actor: owner,
        expected_draft_revision: locked_item.draft_revision,
        expected_draft_digest: locked_item.draft_digest
      )
    end
    assert_equal version.id, item.reload.current_approved_version_id
    connection.execute("SET lock_timeout = DEFAULT")

    release_verifier << true
    writer_thread.join
    proposal_id = writer_result.pop
    assert_kind_of Integer, proposal_id
    locked_item.reload
    approved_version_id = locked_item.approve!(
      actor: owner,
      expected_draft_revision: locked_item.draft_revision,
      expected_draft_digest: locked_item.draft_digest
    ).id
    assert_kind_of Integer, approved_version_id
    assert_equal version.id, CoachPhraseProposal.find(proposal_id).coach_content_item_version_id
    assert_equal approved_version_id, item.reload.current_approved_version_id
    assert_equal version.id, approved_version_id
  ensure
    connection&.execute("SET lock_timeout = DEFAULT")
    S3Service.define_singleton_method(:download_to_io!, original_download) if defined?(original_download) && original_download
    release_verifier << true if defined?(release_verifier) && release_verifier&.empty?
    writer_thread&.join(2)
    cleanup_records
  end

  private

  def phrase_payload
    {
      "text" => "Håfa adai",
      "meaning" => "A reviewed greeting.",
      "allowed_contexts" => [ "greeting" ],
      "prohibited_contexts" => [ "crisis" ],
      "frequency" => "rare",
      "caution" => "Use only as a greeting."
    }
  end

  def approved_phrase_source(owner:, workspace:, source_text:)
    source = CoachContentSource.create!(
      scope: "coach", coach_workspace: workspace, created_by_user: owner, status: "processing",
      filename: "coach-phrases.txt", content_type: "text/plain", byte_size: source_text.bytesize,
      checksum_sha256: Digest::SHA256.hexdigest(source_text.b), s3_key: "test/source/#{SecureRandom.uuid}",
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
      evidence_excerpt: "Håfa adai",
      content_digest: CoachContentSourceCandidate.digest_for(
        title: "Reviewed greeting", kind: "phrase", content: "Håfa adai", topics: [ "greeting" ]
      )
    )
    item = candidate.accept!(actor: owner, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    version = item.approve!(actor: owner, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    [ source.reload, candidate.reload, version ]
  end

  def remember_records(owner:, editor:, workspace:, source:, item:)
    @record_ids = {
      users: [ owner.id, editor.id ], workspace: workspace.id, source: source.id, item: item.id
    }
  end

  def cleanup_records
    return unless @record_ids

    source_id = @record_ids.fetch(:source)
    item_id = @record_ids.fetch(:item)
    proposal_ids = CoachPhraseProposal.where(coach_content_source_id: source_id).pluck(:id)
    CoachPersonaPhrasePromotion.where(coach_phrase_proposal_id: proposal_ids).delete_all
    CoachPhraseAttestation.where(coach_phrase_proposal_id: proposal_ids).delete_all
    CoachPhraseProposal.where(id: proposal_ids).delete_all
    CoachContentItemVersionProvenance.where(coach_content_item_version_id: CoachContentItemVersion.where(coach_content_item_id: item_id)).delete_all
    CoachContentItemDraftProvenance.where(coach_content_item_id: item_id).delete_all
    CoachContentSourceCandidate.where(coach_content_source_id: source_id).delete_all
    CoachContentSource.where(id: source_id).update_all(current_attempt_id: nil)
    CoachContentSourceAttempt.where(coach_content_source_id: source_id).delete_all
    CoachContentSource.where(id: source_id).delete_all
    CoachContentItem.where(id: item_id).update_all(current_approved_version_id: nil)
    CoachContentItemVersion.where(coach_content_item_id: item_id).delete_all
    CoachContentItem.where(id: item_id).delete_all
    CoachProfile.where(coach_workspace_id: @record_ids.fetch(:workspace)).delete_all
    CoachWorkspaceMembership.where(coach_workspace_id: @record_ids.fetch(:workspace)).delete_all
    delete_workspace_brand_records(@record_ids.fetch(:workspace))
    CoachWorkspace.where(id: @record_ids.fetch(:workspace)).delete_all
    User.where(id: @record_ids.fetch(:users)).delete_all
  end
end
