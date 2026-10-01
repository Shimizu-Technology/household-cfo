# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CoachContentSourceJobsTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "processing persists one authoritative generation and duplicate delivery is idempotent" do
    source = queued_source
    candidate = proposed_candidate
    parser = stub_parser
    proposer = Object.new
    proposer.define_singleton_method(:model) { "test-model" }
    proposer.define_singleton_method(:call) do |_segment|
      ContentSources::CandidateProposer::Result.new(candidates: [ candidate ], metadata: { "usage" => { "total_tokens" => 12 } })
    end

    with_processing_stubs(parser, proposer) { CoachContentSourceProcessingJob.perform_now(source.id) }

    assert_equal "needs_review", source.reload.status
    assert_equal 1, source.generation
    assert_equal 1, source.attempts.count
    assert_equal 1, source.candidates.count
    assert_equal "succeeded", source.current_attempt.status

    with_processing_stubs(parser, proposer) { CoachContentSourceProcessingJob.perform_now(source.id) }
    assert_equal 1, source.reload.attempts.count
    assert_equal 1, source.candidates.count
  end

  test "a deletion requested during proposal supersedes the late result" do
    source = queued_source
    parser = stub_parser
    candidate = proposed_candidate
    proposer = Object.new
    proposer.define_singleton_method(:model) { "test-model" }
    proposer.define_singleton_method(:call) do |_segment|
      source.with_lock do
        source.update!(status: "deletion_pending", deletion_requested_at: Time.current, generation: source.generation + 1)
      end
      ContentSources::CandidateProposer::Result.new(candidates: [ candidate ], metadata: {})
    end

    with_processing_stubs(parser, proposer) { CoachContentSourceProcessingJob.perform_now(source.id) }

    assert_equal "deletion_pending", source.reload.status
    assert_empty source.candidates
    assert_equal "superseded", source.attempts.last.status
  end

  test "failed deletion hides source immediately and retries without clearing the key" do
    source = queued_source
    source.update!(status: "deletion_pending", deletion_requested_at: Time.current)
    service_error = Aws::S3::Errors::ServiceError.new(nil, "private canary must not persist")

    with_singleton_method(S3Service, :delete!, ->(_key) { raise service_error }) do
      assert_enqueued_with(job: CoachContentSourceDeletionJob) do
        CoachContentSourceDeletionJob.perform_now(source.id)
      end
    end

    assert_equal "deletion_failed", source.reload.status
    assert_equal "storage_unavailable", source.source_delete_error_code
    assert source.s3_key.present?
    refute source.source_available?
    refute_includes source.attributes.values.compact.join(" "), "private canary"
  end

  test "confirmed deletion redacts unaccepted content and preserves valid tombstones" do
    coach = persona_user
    source = queued_source(owner: coach)
    source.update!(status: "processing", generation: 1)
    attempt = source.attempts.create!(generation: 1, provider: "openrouter", model: "test", prompt_version: "v1", schema_version: "v1", status: "succeeded", started_at: 1.minute.ago, completed_at: Time.current)
    source.update!(status: "deletion_pending", current_attempt: attempt, deletion_requested_at: Time.current, source_deleted_by_user: coach)
    content = "Private source canary 7ZQ"
    digest = CoachContentSourceCandidate.digest_for(title: "Private", kind: "guidance", content: content, topics: [])
    candidate = source.candidates.create!(
      coach_content_source_attempt: attempt,
      position: 0,
      status: "proposed",
      title: "Private",
      kind: "guidance",
      content: content,
      topics: [],
      evidence_locator: { "type" => "text", "segment" => 1, "line_start" => 1, "line_end" => 1, "excerpt_digest" => Digest::SHA256.hexdigest("private") },
      evidence_excerpt: content,
      content_digest: digest
    )

    with_singleton_method(S3Service, :delete!, ->(_key) { true }) { CoachContentSourceDeletionJob.perform_now(source.id) }

    assert_equal "source_deleted", source.reload.status
    assert_nil source.s3_key
    candidate.reload
    assert candidate.valid?
    assert_equal "superseded", candidate.status
    refute_includes "#{candidate.title} #{candidate.content} #{candidate.evidence_excerpt}", "7ZQ"
  end

  test "upload expiry atomically claims and removes an abandoned object intent" do
    source = queued_source
    source.update!(status: "uploading")
    source.update_column(:created_at, 2.hours.ago)
    deleted = []

    with_singleton_method(S3Service, :delete!, ->(key) { deleted << key; true }) do
      assert_difference -> { CoachContentSource.count }, -1 do
        CoachContentSourceUploadExpiryJob.perform_now(source.id)
      end
    end

    assert_equal [ source.s3_key ], deleted
  end

  test "upload cleanup keeps its durable claim when storage deletion retries" do
    source = queued_source
    source.update!(status: "upload_cleanup")
    service_error = Aws::S3::Errors::ServiceError.new(nil, "temporary")

    with_singleton_method(S3Service, :delete!, ->(_key) { raise service_error }) do
      assert_enqueued_with(job: CoachContentSourceUploadExpiryJob, args: [ source.id ]) do
        CoachContentSourceUploadExpiryJob.perform_now(source.id)
      end
    end

    assert_equal "upload_cleanup", source.reload.status
    assert source.s3_key.present?
  end

  test "upload cleanup stops automatic retries after the fifth failed deletion" do
    source = queued_source
    source.update!(status: "upload_cleanup")
    service_error = Aws::S3::Errors::ServiceError.new(nil, "still unavailable")
    job = CoachContentSourceUploadExpiryJob.new(source.id)
    exceptions = [ Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError ]
    job.exception_executions = { exceptions.to_s => 5 }

    with_singleton_method(S3Service, :delete!, ->(_key) { raise service_error }) do
      assert_no_enqueued_jobs do
        assert_raises(Aws::S3::Errors::ServiceError) { job.perform_now }
      end
    end

    assert_equal "upload_cleanup", source.reload.status
    assert source.s3_key.present?
  end

  test "upload expiry cannot delete a source that completed before cleanup claimed it" do
    source = queued_source
    source.update_column(:created_at, 2.hours.ago)
    deleted = []

    with_singleton_method(S3Service, :delete!, ->(key) { deleted << key; true }) do
      CoachContentSourceUploadExpiryJob.perform_now(source.id)
    end

    assert_equal "queued", source.reload.status
    assert_empty deleted
  end

  test "deleting an accepted source redacts raw evidence but preserves approved provenance" do
    coach = persona_user
    source = queued_source(owner: coach, filename: "Jane-Smith-filename-canary-debt.txt")
    source.update!(status: "processing", generation: 1)
    attempt = source.attempts.create!(generation: 1, provider: "openrouter", model: "test", prompt_version: "v1", schema_version: "v1", status: "succeeded", started_at: 1.minute.ago, completed_at: Time.current)
    source.update!(status: "needs_review", current_attempt: attempt, processed_at: Time.current)
    content = "Use one generic next step."
    candidate = source.candidates.create!(
      coach_content_source_attempt: attempt, position: 0, status: "proposed", title: "Generic next step", kind: "guidance",
      content: content, topics: [],
      evidence_locator: { "type" => "text", "segment" => 1, "line_start" => 1, "line_end" => 1, "excerpt_digest" => Digest::SHA256.hexdigest("private evidence canary") },
      evidence_excerpt: "private evidence canary", content_digest: CoachContentSourceCandidate.digest_for(title: "Generic next step", kind: "guidance", content: content, topics: [])
    )
    item = candidate.accept!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    version = item.approve!(actor: coach, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)
    source.update!(status: "deletion_pending", deletion_requested_at: Time.current, source_deleted_by_user: coach)

    with_singleton_method(S3Service, :delete!, ->(_key) { true }) { CoachContentSourceDeletionJob.perform_now(source.id) }

    assert version.source_provenance.reload.integrity_valid?
    assert_equal content, version.reload.content
    assert_equal "accepted", candidate.reload.status
    refute_includes candidate.evidence_excerpt, "private evidence canary"
    refute_includes source.reload.attributes.values.compact.join(" "), "Jane-Smith-filename-canary"
    refute_includes version.source_provenance.attributes.values.compact.join(" "), "Jane-Smith-filename-canary"
  end

  private

  def queued_source(owner: persona_user, filename: "guide.txt")
    CoachContentSource.create!(
      scope: owner.admin? ? "platform" : "coach",
      created_by_user: owner,
      status: "queued",
      filename: filename,
      content_type: "text/plain",
      byte_size: 32,
      checksum_sha256: Digest::SHA256.hexdigest("guide"),
      s3_key: "test/source/#{SecureRandom.uuid}",
      upload_request_id: SecureRandom.uuid
    )
  end

  def stub_parser
    segment = ContentSources::Parser::Segment.new(number: 1, text: "Use one clear next step.", locator: { "type" => "text", "segment" => 1, "line_start" => 1, "line_end" => 1 })
    result = ContentSources::Parser::Result.new(segments: [ segment ], metadata: { format: "text", line_count: 1, character_count: 24, segment_count: 1 })
    Object.new.tap { |parser| parser.define_singleton_method(:call) { |**| result } }
  end

  def proposed_candidate
    title = "One next step"
    content = "Use one clear next step."
    ContentSources::CandidateProposer::Candidate.new(
      title: title,
      kind: "guidance",
      content: content,
      topics: [ "planning" ],
      evidence_excerpt: content,
      evidence_locator: { "type" => "text", "segment" => 1, "line_start" => 1, "line_end" => 1, "excerpt_digest" => Digest::SHA256.hexdigest(content) },
      content_digest: CoachContentSourceCandidate.digest_for(title: title, kind: "guidance", content: content, topics: [ "planning" ])
    )
  end

  def with_processing_stubs(parser, proposer)
    with_singleton_method(ContentSources::Parser, :new, -> { parser }) do
      with_singleton_method(ContentSources::CandidateProposer, :new, -> { proposer }) do
        with_singleton_method(S3Service, :download_to_io!, ->(_key, io) { io.write("source"); io.flush; true }) { yield }
      end
    end
  end

  def with_singleton_method(target, name, implementation)
    original = target.method(name)
    target.define_singleton_method(name, implementation)
    yield
  ensure
    target.define_singleton_method(name, original)
  end
end
