# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CoachContentSourceUrlIntakeJobsTest < ActiveSupport::TestCase
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "job stages one immutable snapshot, registers a URL source, and queues existing processing" do
    coach = persona_user
    intake = url_intake(coach: coach)
    tempfile = Tempfile.new([ "url-intake-test", ".txt" ])
    tempfile.write("Choose one clear next step for the household.\n")
    tempfile.flush
    checksum = Digest::SHA256.file(tempfile.path).hexdigest
    result = ContentSources::FetchSandbox::Result.new(
      tempfile: tempfile, filename: "web-source-#{checksum.first(12)}.txt", content_type: "text/plain",
      byte_size: File.size(tempfile.path), checksum_sha256: checksum, redirect_count: 1
    )
    sandbox = Object.new
    sandbox.define_singleton_method(:call) { |_url| result }
    uploaded = []
    copied = []
    deleted = []

    with_singleton_method(ContentSources::FetchSandbox, :new, -> { sandbox }) do
      with_singleton_method(S3Service, :upload_file!, ->(key, path, **) { uploaded << [ key, File.binread(path) ]; key }) do
        with_singleton_method(S3Service, :copy!, ->(source, destination) { copied << [ source, destination ]; destination }) do
          metadata = {
            byte_size: result.byte_size,
            content_type: result.content_type,
            checksum_sha256: Base64.strict_encode64([ checksum ].pack("H*")),
            server_side_encryption: "AES256"
          }
          with_singleton_method(S3Service, :object_metadata, ->(*) { metadata }) do
            with_singleton_method(S3Service, :delete!, ->(key) { deleted << key; true }) do
              assert_enqueued_with(job: CoachContentSourceProcessingJob) do
                CoachContentSourceUrlIntakeJob.perform_now(intake.id)
              end
            end
          end
        end
      end
    end

    intake.reload
    source = intake.coach_content_source
    assert_equal "registered", intake.status
    assert_equal "url_snapshot", source.ingestion_method
    assert_equal "queued", source.status
    assert_equal checksum, source.checksum_sha256
    assert_equal 1, intake.redirect_count
    assert_equal 1, uploaded.length
    assert_equal 1, copied.length
    assert_equal [ uploaded.first.first ], deleted
    refute_includes source.attributes.values.compact.join(" "), "private=canary"
  end

  test "permission is checked again after fetch and a revoked editor never registers a source" do
    owner = persona_user
    editor = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: owner).call
    membership = workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    intake = url_intake(coach: editor, workspace: workspace)
    tempfile = Tempfile.new([ "url-intake-test", ".txt" ])
    tempfile.write("Choose one clear next step for the household.\n")
    tempfile.flush
    checksum = Digest::SHA256.file(tempfile.path).hexdigest
    result = ContentSources::FetchSandbox::Result.new(
      tempfile: tempfile, filename: "guide.txt", content_type: "text/plain", byte_size: File.size(tempfile.path),
      checksum_sha256: checksum, redirect_count: 0
    )
    sandbox = Object.new
    sandbox.define_singleton_method(:call) do |_url|
      membership.destroy!
      result
    end

    with_singleton_method(ContentSources::FetchSandbox, :new, -> { sandbox }) do
      with_singleton_method(S3Service, :upload_file!, ->(key, *, **) { key }) do
        assert_no_difference -> { CoachContentSource.count } do
          CoachContentSourceUrlIntakeJob.perform_now(intake.id)
        end
      end
    end

    assert_equal "cleanup_pending", intake.reload.status
    assert_equal "url_intake_unavailable", intake.error_code
    assert_nil intake.coach_content_source
  end

  test "fetch failure stores only a safe code and releases the reservation" do
    coach = persona_user
    intake = url_intake(coach: coach, url: "https://example.com/private?canary=7ZQ")
    sandbox = Object.new
    sandbox.define_singleton_method(:call) { |_url| raise ContentSources::Error, "url_fetch_failed" }

    with_singleton_method(ContentSources::FetchSandbox, :new, -> { sandbox }) do
      CoachContentSourceUrlIntakeJob.perform_now(intake.id)
    end

    intake.reload
    assert_equal "failed", intake.status
    assert_equal "url_fetch_failed", intake.error_code
    refute_includes intake.attributes.except("encrypted_url_ciphertext", "encrypted_url_iv", "encrypted_url_auth_tag").values.compact.join(" "), "7ZQ"
    assert_empty CoachContentSourceUrlIntake.reserving_quota.where(id: intake.id)
  end

  test "source deletion redacts the encrypted URL and marks the intake deleted" do
    coach = persona_user
    source = CoachContentSource.create!(
      scope: "coach", created_by_user: coach, status: "deletion_pending", ingestion_method: "url_snapshot",
      filename: "guide.txt", content_type: "text/plain", byte_size: 5,
      checksum_sha256: Digest::SHA256.hexdigest("guide"), s3_key: "test/#{SecureRandom.uuid}",
      upload_request_id: SecureRandom.uuid, deletion_requested_at: Time.current, source_deleted_by_user: coach
    )
    intake = url_intake(coach: coach, source: source, status: "registered")

    with_singleton_method(S3Service, :delete!, ->(*) { true }) { CoachContentSourceDeletionJob.perform_now(source.id) }

    intake.reload
    assert_equal "deleted", intake.status
    assert_nil intake.encrypted_url_ciphertext
    assert_nil intake.encrypted_url_iv
    assert_nil intake.encrypted_url_auth_tag
  end

  test "accepted URL guidance seals snapshot ingestion into immutable provenance" do
    coach = persona_user
    source = CoachContentSource.create!(
      scope: "coach", created_by_user: coach, status: "processing", generation: 1,
      ingestion_method: "url_snapshot", filename: "web-source.txt", content_type: "text/plain", byte_size: 42,
      checksum_sha256: Digest::SHA256.hexdigest("snapshot"), s3_key: "test/#{SecureRandom.uuid}",
      upload_request_id: SecureRandom.uuid
    )
    attempt = source.attempts.create!(
      generation: 1, provider: "openrouter", model: "test", prompt_version: "v1", schema_version: "v1",
      status: "succeeded", started_at: 1.minute.ago, completed_at: Time.current
    )
    source.update!(status: "needs_review", current_attempt: attempt)
    content = "Choose one clear next step."
    candidate = source.candidates.create!(
      coach_content_source_attempt: attempt, position: 0, status: "proposed", title: "One step",
      kind: "guidance", content: content, topics: [],
      evidence_locator: { "type" => "text", "segment" => 1, "line_start" => 1, "line_end" => 1, "excerpt_digest" => Digest::SHA256.hexdigest(content) },
      evidence_excerpt: content,
      content_digest: CoachContentSourceCandidate.digest_for(title: "One step", kind: "guidance", content: content, topics: [])
    )

    item = candidate.accept!(actor: coach, expected_revision: candidate.revision, expected_digest: candidate.content_digest)
    version = item.approve!(actor: coach, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)

    assert_equal "url_snapshot", item.draft_source_provenance.source_ingestion_method
    assert_equal "url_snapshot", version.source_provenance.source_ingestion_method
    assert item.draft_source_provenance.integrity_valid?
    assert version.source_provenance.integrity_valid?
  end

  private

  def url_intake(coach:, workspace: nil, url: "https://example.com/guide?private=canary", source: nil, status: "queued")
    workspace ||= CoachWorkspaces::Resolver.new(user: coach).call
    encrypted = ContentSources::UrlCipher.encrypt(url)
    CoachContentSourceUrlIntake.create!(
      scope: "coach", coach_workspace: workspace, created_by_user: coach, coach_content_source: source,
      request_id: source&.upload_request_id || SecureRandom.uuid,
      encrypted_url_ciphertext: encrypted.fetch(:ciphertext), encrypted_url_iv: encrypted.fetch(:iv),
      encrypted_url_auth_tag: encrypted.fetch(:auth_tag), encryption_key_version: encrypted.fetch(:key_version),
      url_identity_hmac: ContentSources::UrlCipher.identity(url), hmac_key_version: 1,
      status: status, reserved_bytes: source&.byte_size || CoachContentSourceUrlIntakeJob::RESERVATION_BYTES,
      final_s3_key: source&.s3_key
    )
  end

  def with_singleton_method(target, name, implementation)
    original = target.method(name)
    target.define_singleton_method(name, implementation)
    yield
  ensure
    target.define_singleton_method(name, original)
  end
end
