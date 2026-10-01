# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminCoachContentSourcesControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "participants are denied and coaches cannot see another coach source" do
    owner = persona_user
    other = persona_user
    participant = persona_user(role: "participant")
    source = content_source(owner: owner)

    get "/api/v1/admin/content_sources", headers: auth_headers(participant)
    assert_response :forbidden

    get "/api/v1/admin/content_sources", headers: auth_headers(other)
    assert_response :success
    assert_empty response.parsed_body.fetch("sources")

    get "/api/v1/admin/content_sources/#{source.id}", headers: auth_headers(other)
    assert_response :not_found
  end

  test "presign uses an opaque coach-scoped encrypted checksum-bound upload" do
    coach = persona_user
    captured_key = nil
    checksum = Digest::SHA256.hexdigest("guide")
    grant = { url: "https://private.example/upload", headers: { "x-amz-server-side-encryption" => "AES256" }, expires_in: 900 }

    with_singleton_method(S3Service, :configured?, -> { true }) do
      with_singleton_method(S3Service, :presigned_upload, ->(key, **) { captured_key = key; grant }) do
        assert_enqueued_with(job: CoachContentSourceUploadExpiryJob) do
          post "/api/v1/admin/content_sources/presign", params: {
            filename: "Mrs Mel guide.txt",
            content_type: "text/plain",
            byte_size: 5,
            checksum_sha256: checksum,
            upload_request_id: SecureRandom.uuid,
            scope: "platform"
          }, headers: auth_headers(coach), as: :json
        end
      end
    end

    assert_response :success
    assert_includes captured_key, "/coach_content_sources/#{coach.id}/"
    refute_includes captured_key, "Mel"
    refute_includes captured_key, ".txt"
    assert_equal "AES256", response.parsed_body.dig("upload_headers", "x-amz-server-side-encryption")
    token = Rails.application.message_verifier(:coach_content_source_direct_upload).verify(response.parsed_body.fetch("upload_token")).deep_symbolize_keys
    intent = CoachContentSource.find(token.fetch(:source_id))
    assert_equal "uploading", intent.status
    assert_equal captured_key, intent.s3_key

    get "/api/v1/admin/content_sources", headers: auth_headers(coach)
    assert_empty response.parsed_body.fetch("sources")
  end

  test "presign provider failure moves the durable intent into cleanup" do
    coach = persona_user
    checksum = Digest::SHA256.hexdigest("guide")

    with_singleton_method(S3Service, :configured?, -> { true }) do
      with_singleton_method(S3Service, :presigned_upload, ->(*) { nil }) do
        assert_enqueued_with(job: CoachContentSourceUploadExpiryJob) do
          post "/api/v1/admin/content_sources/presign", params: {
            filename: "guide.txt", content_type: "text/plain", byte_size: 5,
            checksum_sha256: checksum, upload_request_id: SecureRandom.uuid, scope: "coach"
          }, headers: auth_headers(coach), as: :json
        end
      end
    end

    assert_response :service_unavailable
    assert_equal "upload_cleanup", CoachContentSource.find_by!(created_by_user: coach).status
  end

  test "presign provider exception also moves the durable intent into cleanup" do
    coach = persona_user
    checksum = Digest::SHA256.hexdigest("guide")
    service_error = Aws::S3::Errors::ServiceError.new(nil, "temporary")

    with_singleton_method(S3Service, :configured?, -> { true }) do
      with_singleton_method(S3Service, :presigned_upload, ->(*) { raise service_error }) do
        assert_enqueued_with(job: CoachContentSourceUploadExpiryJob) do
          post "/api/v1/admin/content_sources/presign", params: {
            filename: "guide.txt", content_type: "text/plain", byte_size: 5,
            checksum_sha256: checksum, upload_request_id: SecureRandom.uuid, scope: "coach"
          }, headers: auth_headers(coach), as: :json
        end
      end
    end

    assert_response :service_unavailable
    assert_equal "upload_cleanup", CoachContentSource.find_by!(created_by_user: coach).status
  end

  test "source count quota allows the hundredth active source and isolates owners" do
    coach = persona_user
    other = persona_user
    99.times { content_source(owner: coach) }
    5.times { content_source(owner: other) }
    CoachContentSource.where(created_by_user: [ coach, other ]).update_all(created_at: 1.day.ago)

    with_presign_grant do
      post_source_presign(coach, request_id: SecureRandom.uuid, checksum: Digest::SHA256.hexdigest("hundredth"))
    end
    assert_response :success
    assert_equal 100, CoachContentSource.where(created_by_user: coach).where.not(status: "source_deleted").count

    with_presign_grant do
      post_source_presign(coach, request_id: SecureRandom.uuid, checksum: Digest::SHA256.hexdigest("over-count"))
    end
    assert_response :unprocessable_entity
    assert_equal "source_quota_reached", response.parsed_body.fetch("code")

    with_presign_grant do
      post_source_presign(other, request_id: SecureRandom.uuid, checksum: Digest::SHA256.hexdigest("other-owner"))
    end
    assert_response :success
  end

  test "source byte quota is enforced per owner" do
    coach = persona_user
    other = persona_user
    content_source(owner: coach).update_column(:byte_size, CoachContentSource::MAX_ACTIVE_BYTES_PER_OWNER)

    with_presign_grant do
      post_source_presign(coach, request_id: SecureRandom.uuid, checksum: Digest::SHA256.hexdigest("over-bytes"))
    end
    assert_response :unprocessable_entity
    assert_equal "source_quota_reached", response.parsed_body.fetch("code")

    with_presign_grant do
      post_source_presign(other, request_id: SecureRandom.uuid, checksum: Digest::SHA256.hexdigest("isolated-bytes"))
    end
    assert_response :success
  end

  test "in-flight and recent-upload limits bound spend without blocking an idempotent retry" do
    coach = persona_user
    intents = 5.times.map { |index| upload_intent(owner: coach, key: "test/opaque/in-flight-#{index}") }

    with_presign_grant do
      post_source_presign(coach, request_id: SecureRandom.uuid, checksum: Digest::SHA256.hexdigest("sixth-in-flight"))
    end
    assert_response :unprocessable_entity
    assert_equal "upload_limit_reached", response.parsed_body.fetch("code")

    original = intents.first
    with_presign_grant do
      post_source_presign(coach, request_id: original.upload_request_id, checksum: original.checksum_sha256)
    end
    assert_response :success
    assert_equal 5, CoachContentSource.where(created_by_user: coach, status: "uploading").count

    rate_limited = persona_user
    10.times { content_source(owner: rate_limited) }
    with_presign_grant do
      post_source_presign(rate_limited, request_id: SecureRandom.uuid, checksum: Digest::SHA256.hexdigest("eleventh-recent"))
    end
    assert_response :unprocessable_entity
    assert_equal "upload_rate_limited", response.parsed_body.fetch("code")
  end

  test "complete is idempotent and retries enqueue a stranded queued source" do
    coach = persona_user
    file_content = "guide"
    checksum = Digest::SHA256.hexdigest(file_content)
    request_id = SecureRandom.uuid
    intent = upload_intent(owner: coach, key: "test/opaque/source", request_id: request_id, checksum: checksum, byte_size: file_content.bytesize)
    token = Rails.application.message_verifier(:coach_content_source_direct_upload).generate({
      filename: "guide.txt",
      content_type: "text/plain",
      byte_size: file_content.bytesize,
      checksum_sha256: checksum,
      upload_request_id: request_id,
      scope: "coach",
      s3_key: "test/opaque/source",
      source_id: intent.id,
      user_id: coach.id
    }, expires_in: 15.minutes)
    metadata = {
      byte_size: file_content.bytesize,
      content_type: "text/plain",
      checksum_sha256: Base64.strict_encode64([ checksum ].pack("H*")),
      etag: "etag",
      server_side_encryption: "AES256"
    }

    with_upload_stubs(metadata, file_content) do
      assert_enqueued_with(job: CoachContentSourceProcessingJob) do
        assert_no_difference -> { CoachContentSource.count } do
          post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: auth_headers(coach), as: :json
        end
      end
      assert_response :created

      assert_enqueued_with(job: CoachContentSourceProcessingJob) do
        assert_no_difference -> { CoachContentSource.count } do
          post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: auth_headers(coach), as: :json
        end
      end
      assert_response :success
    end
  end

  test "candidate acceptance returns one standard unapproved item draft" do
    coach = persona_user
    source, candidate = reviewable_candidate(owner: coach)

    assert_difference -> { CoachContentItem.count }, 1 do
      post "/api/v1/admin/content_sources/#{source.id}/candidates/#{candidate.id}/accept", params: {
        candidate: { revision: candidate.revision, digest: candidate.content_digest }
      }, headers: auth_headers(coach), as: :json
    end

    assert_response :success
    item = CoachContentItem.find(response.parsed_body.dig("item", "id"))
    assert_nil item.current_approved_version
    refute item.draft_always_on
    assert_equal "accepted", response.parsed_body.dig("candidate", "status")
  end

  test "a transient storage error keeps the bound intent verifiable on the same-token retry" do
    coach = persona_user
    content = "guide"
    checksum = Digest::SHA256.hexdigest(content)
    intent = upload_intent(owner: coach, key: "test/opaque/transient", checksum: checksum, byte_size: content.bytesize)
    token = Rails.application.message_verifier(:coach_content_source_direct_upload).generate({
      filename: intent.filename, content_type: intent.content_type, byte_size: intent.byte_size,
      checksum_sha256: intent.checksum_sha256, upload_request_id: intent.upload_request_id,
      scope: intent.scope, s3_key: intent.s3_key, source_id: intent.id, user_id: coach.id
    }, expires_in: 15.minutes)
    service_error = Aws::S3::Errors::ServiceError.new(nil, "temporary")

    with_singleton_method(S3Service, :configured?, -> { true }) do
      with_singleton_method(S3Service, :object_metadata, ->(_key) { raise service_error }) do
        post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: auth_headers(coach), as: :json
      end
    end
    assert_response :service_unavailable
    assert_equal "verifying", intent.reload.status

    metadata = {
      byte_size: content.bytesize, content_type: "text/plain",
      checksum_sha256: Base64.strict_encode64([ checksum ].pack("H*")), etag: "etag", server_side_encryption: "AES256"
    }
    with_upload_stubs(metadata, content) do
      assert_enqueued_with(job: CoachContentSourceProcessingJob, args: [ intent.id ]) do
        post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: auth_headers(coach), as: :json
      end
    end
    assert_response :created
    assert_equal "queued", intent.reload.status
  end

  test "different upload requests for the same owner scope and checksum leave one queued source" do
    coach = persona_user
    content = "guide"
    checksum = Digest::SHA256.hexdigest(content)
    intents = 2.times.map { |index| upload_intent(owner: coach, key: "test/opaque/same-#{index}", checksum: checksum, byte_size: content.bytesize) }
    tokens = intents.map do |intent|
      Rails.application.message_verifier(:coach_content_source_direct_upload).generate({
        filename: intent.filename, content_type: intent.content_type, byte_size: intent.byte_size,
        checksum_sha256: intent.checksum_sha256, upload_request_id: intent.upload_request_id,
        scope: intent.scope, s3_key: intent.s3_key, source_id: intent.id, user_id: coach.id
      }, expires_in: 15.minutes)
    end
    metadata = {
      byte_size: content.bytesize, content_type: "text/plain",
      checksum_sha256: Base64.strict_encode64([ checksum ].pack("H*")), etag: "etag", server_side_encryption: "AES256"
    }

    with_upload_stubs(metadata, content) do
      tokens.each do |token|
        post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: auth_headers(coach), as: :json
        assert_response :success
      end
    end

    assert_equal 1, CoachContentSource.where(created_by_user: coach, status: "queued", checksum_sha256: checksum).count
    assert_equal 1, CoachContentSource.where(created_by_user: coach, status: "upload_cleanup", checksum_sha256: checksum).count
  end

  test "a response-loss retry with the same file returns the existing source and cleans the losing upload" do
    coach = persona_user
    existing = content_source(owner: coach)
    checksum = existing.checksum_sha256
    losing_key = "test/opaque/retry-source"
    intent = upload_intent(owner: coach, key: losing_key, checksum: checksum, byte_size: 5)
    token = Rails.application.message_verifier(:coach_content_source_direct_upload).generate({
      filename: "renamed-guide.txt",
      content_type: "text/plain",
      byte_size: 5,
      checksum_sha256: checksum,
      upload_request_id: intent.upload_request_id,
      scope: "coach",
      s3_key: losing_key,
      source_id: intent.id,
      user_id: coach.id
    }, expires_in: 15.minutes)
    with_singleton_method(S3Service, :configured?, -> { true }) do
      assert_enqueued_with(job: CoachContentSourceProcessingJob, args: [ existing.id ]) do
        assert_enqueued_with(job: CoachContentSourceUploadExpiryJob, args: [ intent.id ]) do
          post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: auth_headers(coach), as: :json
        end
      end
    end

    assert_response :success
    assert_equal existing.id, response.parsed_body.dig("source", "id")
    assert_equal "upload_cleanup", intent.reload.status
  end

  test "deletion request immediately hides source download and schedules truthful cleanup" do
    coach = persona_user
    source = content_source(owner: coach)

    assert_enqueued_with(job: CoachContentSourceDeletionJob) do
      delete "/api/v1/admin/content_sources/#{source.id}/source", headers: auth_headers(coach)
    end
    assert_response :accepted
    assert_equal "deletion_pending", source.reload.status
    refute source.source_available?

    get "/api/v1/admin/content_sources/#{source.id}/source_url", headers: auth_headers(coach)
    assert_response :gone
  end

  private

  def with_upload_stubs(metadata, content)
    with_singleton_method(S3Service, :configured?, -> { true }) do
      with_singleton_method(S3Service, :object_metadata, ->(_key) { metadata }) do
        with_singleton_method(S3Service, :download_to_io!, ->(_key, io) { io.write(content); io.flush; true }) { yield }
      end
    end
  end

  def with_presign_grant(&block)
    grant = { url: "https://private.example/upload", headers: { "x-amz-server-side-encryption" => "AES256" }, expires_in: 900 }
    with_singleton_method(S3Service, :configured?, -> { true }) do
      with_singleton_method(S3Service, :presigned_upload, ->(*) { grant }, &block)
    end
  end

  def post_source_presign(user, request_id:, checksum:)
    post "/api/v1/admin/content_sources/presign", params: {
      filename: "guide.txt", content_type: "text/plain", byte_size: 5,
      checksum_sha256: checksum, upload_request_id: request_id, scope: "coach"
    }, headers: auth_headers(user), as: :json
  end

  def with_singleton_method(target, name, implementation)
    original = target.method(name)
    target.define_singleton_method(name, implementation)
    yield
  ensure
    target.define_singleton_method(name, original)
  end

  def content_source(owner:)
    CoachContentSource.create!(
      scope: owner.admin? ? "platform" : "coach",
      created_by_user: owner,
      status: "queued",
      filename: "guide.txt",
      content_type: "text/plain",
      byte_size: 5,
      checksum_sha256: Digest::SHA256.hexdigest("guide"),
      s3_key: "test/source/#{SecureRandom.uuid}",
      upload_request_id: SecureRandom.uuid
    )
  end

  def upload_intent(owner:, key:, request_id: SecureRandom.uuid, checksum: Digest::SHA256.hexdigest("guide"), byte_size: 5, scope: "coach")
    CoachContentSource.create!(
      scope: scope,
      created_by_user: owner,
      status: "uploading",
      filename: "guide.txt",
      content_type: "text/plain",
      byte_size: byte_size,
      checksum_sha256: checksum,
      s3_key: key,
      upload_request_id: request_id
    )
  end

  def reviewable_candidate(owner:)
    source = content_source(owner: owner)
    source.update!(status: "processing", generation: 1)
    attempt = source.attempts.create!(generation: 1, provider: "openrouter", model: "test", prompt_version: "v1", schema_version: "v1", status: "succeeded", started_at: 1.minute.ago, completed_at: Time.current)
    source.update!(status: "needs_review", current_attempt: attempt, processed_at: Time.current)
    title = "One next step"
    content = "Choose one practical next step."
    candidate = source.candidates.create!(
      coach_content_source_attempt: attempt,
      position: 0,
      status: "proposed",
      title: title,
      kind: "guidance",
      content: content,
      topics: [ "planning" ],
      evidence_locator: { "type" => "text", "segment" => 1, "line_start" => 1, "line_end" => 1, "excerpt_digest" => Digest::SHA256.hexdigest(content) },
      evidence_excerpt: content,
      content_digest: CoachContentSourceCandidate.digest_for(title: title, kind: "guidance", content: content, topics: [ "planning" ])
    )
    [ source, candidate ]
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
