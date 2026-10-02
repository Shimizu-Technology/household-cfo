# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class MiaApprovedSourcePhraseLockingTest < ActiveSupport::TestCase
  include PersonaTestHelper

  self.use_transactional_tests = false

  test "current phrase item approval waits until proposal evidence is sealed" do
    owner = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: owner).call
    editor = persona_user
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    source_text = "Håfa adai. Keep one practical next step."
    source, candidate, version = approved_phrase_source(owner:, workspace:, source_text:)
    item = version.coach_content_item
    item.update!(draft_content: "Håfa adai. Revised approved wording.")
    remember_records(owner:, editor:, workspace:, source:, item:)

    verifier_entered = Queue.new
    release_verifier = Queue.new
    writer_result = Queue.new
    approval_pid = Queue.new
    approval_result = Queue.new
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

    approval_thread = Thread.new do
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        approval_pid << connection.select_value("SELECT pg_backend_pid()").to_i
        begin
          locked_item = CoachContentItem.find(item.id)
          approved = locked_item.approve!(
            actor: User.find(owner.id),
            expected_draft_revision: locked_item.draft_revision,
            expected_draft_digest: locked_item.draft_digest
          )
          approval_result << approved.id
        rescue StandardError => error
          approval_result << error
        end
      end
    end

    assert wait_for_database_lock(approval_pid.pop), "expected approval to wait on the locked content item"
    assert_equal version.id, item.reload.current_approved_version_id

    release_verifier << true
    writer_thread.join
    approval_thread.join
    proposal_id = writer_result.pop
    approved_version_id = approval_result.pop
    assert_kind_of Integer, proposal_id
    assert_kind_of Integer, approved_version_id
    assert_equal version.id, CoachPhraseProposal.find(proposal_id).coach_content_item_version_id
    assert_equal approved_version_id, item.reload.current_approved_version_id
    refute_equal version.id, approved_version_id
  ensure
    S3Service.define_singleton_method(:download_to_io!, original_download) if defined?(original_download) && original_download
    release_verifier << true if defined?(release_verifier) && release_verifier&.empty?
    writer_thread&.join(2)
    approval_thread&.join(2)
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

  def wait_for_database_lock(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
    loop do
      wait_type = ActiveRecord::Base.connection.select_value(
        "SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}"
      )
      return true if wait_type == "Lock"
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
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
    CoachWorkspace.where(id: @record_ids.fetch(:workspace)).delete_all
    User.where(id: @record_ids.fetch(:users)).delete_all
  end
end
