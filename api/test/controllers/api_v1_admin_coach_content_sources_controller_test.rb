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

  test "workspace reviewer can inspect and download sources then accept or reject candidates without editor actions" do
    owner = persona_user
    reviewer = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: owner).call
    workspace.coach_workspace_memberships.create!(user: reviewer, role: "reviewer")
    accepted_source, accepted_candidate = reviewable_candidate(owner: owner)
    rejected_source, rejected_candidate = reviewable_candidate(owner: owner)
    headers = workspace_auth_headers(reviewer, workspace)

    get "/api/v1/admin/content_sources", headers: headers
    assert_response :success
    listed_source = response.parsed_body.fetch("sources").find { |source| source.fetch("id") == accepted_source.id }
    assert listed_source
    assert_equal({
      "edit_candidates" => false, "review_candidates" => true, "download" => true,
      "reprocess" => false, "delete" => false
    }, listed_source.fetch("permissions"))
    assert_equal false, response.parsed_body.dig("permissions", "upload_coach")

    get "/api/v1/admin/content_sources/#{accepted_source.id}", headers: headers
    assert_response :success
    assert_equal accepted_candidate.id, response.parsed_body.dig("source", "candidates", 0, "id")

    with_singleton_method(S3Service, :presigned_url, ->(*) { "https://private.example/reviewer-download" }) do
      get "/api/v1/admin/content_sources/#{accepted_source.id}/source_url", headers: headers
    end
    assert_response :success
    assert_equal "https://private.example/reviewer-download", response.parsed_body.fetch("url")

    post "/api/v1/admin/content_sources/#{accepted_source.id}/reprocess", headers: headers, as: :json
    assert_response :not_found
    delete "/api/v1/admin/content_sources/#{accepted_source.id}/source", headers: headers
    assert_response :not_found

    owner.update_columns(role: "participant")

    post "/api/v1/admin/content_sources/#{accepted_source.id}/candidates/#{accepted_candidate.id}/accept", params: {
      candidate: { revision: accepted_candidate.revision, digest: accepted_candidate.content_digest }
    }, headers: headers, as: :json
    assert_response :success
    assert_equal "accepted", accepted_candidate.reload.status
    assert_equal owner, accepted_candidate.accepted_content_item.created_by_user

    post "/api/v1/admin/content_sources/#{rejected_source.id}/candidates/#{rejected_candidate.id}/reject", params: {
      candidate: { revision: rejected_candidate.revision, digest: rejected_candidate.content_digest }
    }, headers: headers, as: :json
    assert_response :success
    assert_equal "rejected", rejected_candidate.reload.status

    post "/api/v1/admin/content_sources/presign", params: {
      filename: "reviewer.txt", content_type: "text/plain", byte_size: 5,
      checksum_sha256: Digest::SHA256.hexdigest("guide"), upload_request_id: SecureRandom.uuid, scope: "coach"
    }, headers: headers, as: :json
    assert_response :forbidden
  end

  test "workspace editor can open and edit source candidates without review actions" do
    owner = persona_user
    editor = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: owner).call
    workspace.coach_workspace_memberships.create!(user: editor, role: "editor")
    source, candidate = reviewable_candidate(owner: owner)
    headers = workspace_auth_headers(editor, workspace)

    get "/api/v1/admin/content_sources", headers: headers
    assert_response :success
    listed_source = response.parsed_body.fetch("sources").find { |entry| entry.fetch("id") == source.id }
    assert_equal true, response.parsed_body.dig("permissions", "upload_coach")
    assert_equal({
      "edit_candidates" => true, "review_candidates" => false, "download" => true,
      "reprocess" => true, "delete" => true
    }, listed_source.fetch("permissions"))

    get "/api/v1/admin/content_sources/#{source.id}", headers: headers
    assert_response :success

    patch "/api/v1/admin/content_sources/#{source.id}/candidates/#{candidate.id}", params: {
      candidate: {
        title: "Editor revised title", kind: candidate.kind, content: candidate.content,
        topics: candidate.topics, revision: candidate.revision, digest: candidate.content_digest
      }
    }, headers: headers, as: :json
    assert_response :success
    assert_equal "Editor revised title", candidate.reload.title

    post "/api/v1/admin/content_sources/#{source.id}/candidates/#{candidate.id}/accept", params: {
      candidate: { revision: candidate.revision, digest: candidate.content_digest }
    }, headers: headers, as: :json
    assert_response :not_found
  end

  test "workspace viewer cannot list, inspect, or upload private sources" do
    owner = persona_user
    viewer = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: owner).call
    workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")
    source = content_source(owner: owner)
    headers = workspace_auth_headers(viewer, workspace)

    get "/api/v1/admin/content_sources", headers: headers
    assert_response :success
    assert_empty response.parsed_body.fetch("sources")
    assert_equal false, response.parsed_body.dig("permissions", "upload_coach")

    get "/api/v1/admin/content_sources/#{source.id}", headers: headers
    assert_response :not_found

    post "/api/v1/admin/content_sources/presign", params: {
      filename: "viewer.txt", content_type: "text/plain", byte_size: 5,
      checksum_sha256: Digest::SHA256.hexdigest("guide"), upload_request_id: SecureRandom.uuid, scope: "coach"
    }, headers: headers, as: :json
    assert_response :forbidden
  end

  test "platform upload token survives a workspace switch while a coach upload token does not" do
    admin = persona_user(role: "admin")
    first_owner = persona_user
    second_owner = persona_user
    first_workspace = CoachWorkspaces::Resolver.new(user: first_owner).call
    second_workspace = CoachWorkspaces::Resolver.new(user: second_owner).call
    content = "guide"
    checksum = Digest::SHA256.hexdigest(content)

    platform_token = nil
    with_presign_grant do
      post "/api/v1/admin/content_sources/presign", params: {
        filename: "platform-guide.txt", content_type: "text/plain", byte_size: content.bytesize,
        checksum_sha256: checksum, upload_request_id: SecureRandom.uuid, scope: "platform"
      }, headers: workspace_auth_headers(admin, first_workspace), as: :json
      platform_token = response.parsed_body.fetch("upload_token")
    end
    assert_response :success
    platform_metadata = Rails.application.message_verifier(:coach_content_source_direct_upload).verify(platform_token).deep_symbolize_keys
    assert_nil platform_metadata[:coach_workspace_id]

    object_metadata = {
      byte_size: content.bytesize, content_type: "text/plain",
      checksum_sha256: Base64.strict_encode64([ checksum ].pack("H*")), etag: "etag", server_side_encryption: "AES256"
    }
    with_upload_stubs(object_metadata, content) do
      post "/api/v1/admin/content_sources/complete", params: { upload_token: platform_token },
        headers: workspace_auth_headers(admin, second_workspace), as: :json
    end
    assert_response :created
    assert_equal "platform", response.parsed_body.dig("source", "scope")

    coach_token = nil
    with_presign_grant do
      post "/api/v1/admin/content_sources/presign", params: {
        filename: "coach-guide.txt", content_type: "text/plain", byte_size: content.bytesize,
        checksum_sha256: checksum, upload_request_id: SecureRandom.uuid, scope: "coach"
      }, headers: workspace_auth_headers(admin, first_workspace), as: :json
      coach_token = response.parsed_body.fetch("upload_token")
    end
    assert_response :success
    coach_metadata = Rails.application.message_verifier(:coach_content_source_direct_upload).verify(coach_token).deep_symbolize_keys
    assert_equal first_workspace.id, coach_metadata.fetch(:coach_workspace_id)

    with_singleton_method(S3Service, :configured?, -> { true }) do
      post "/api/v1/admin/content_sources/complete", params: { upload_token: coach_token },
        headers: auth_headers(admin), as: :json
    end
    assert_response :forbidden
    assert_equal "content_source_forbidden", response.parsed_body.fetch("code")

    with_singleton_method(S3Service, :configured?, -> { true }) do
      post "/api/v1/admin/content_sources/complete", params: { upload_token: coach_token },
        headers: workspace_auth_headers(admin, second_workspace), as: :json
    end
    assert_response :forbidden
    assert_equal "content_source_forbidden", response.parsed_body.fetch("code")
  end

  test "coach upload completion fails closed and cleans the intent after upload permission is removed" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    membership = workspace.coach_workspace_memberships.find_by!(user: coach)
    headers = workspace_auth_headers(coach, workspace)
    checksum = Digest::SHA256.hexdigest("guide")

    token = nil
    with_presign_grant do
      post "/api/v1/admin/content_sources/presign", params: {
        filename: "coach-guide.txt", content_type: "text/plain", byte_size: 5,
        checksum_sha256: checksum, upload_request_id: SecureRandom.uuid, scope: "coach"
      }, headers: headers, as: :json
      token = response.parsed_body.fetch("upload_token")
    end
    assert_response :success
    intent = CoachContentSource.find(
      Rails.application.message_verifier(:coach_content_source_direct_upload).verify(token).deep_symbolize_keys.fetch(:source_id)
    )
    membership.update!(role: "viewer")
    clear_enqueued_jobs

    with_singleton_method(S3Service, :configured?, -> { true }) do
      assert_enqueued_with(job: CoachContentSourceUploadExpiryJob, args: [ intent.id ]) do
        post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: headers, as: :json
      end
    end

    assert_response :forbidden
    assert_equal "content_source_forbidden", response.parsed_body.fetch("code")
    assert_equal "upload_cleanup", intent.reload.status
    assert_no_enqueued_jobs only: CoachContentSourceProcessingJob
  end

  test "coach upload completion cleans its bound intent after workspace membership is removed" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    headers = workspace_auth_headers(coach, workspace)
    checksum = Digest::SHA256.hexdigest("guide")

    token = nil
    with_presign_grant do
      post "/api/v1/admin/content_sources/presign", params: {
        filename: "coach-guide.txt", content_type: "text/plain", byte_size: 5,
        checksum_sha256: checksum, upload_request_id: SecureRandom.uuid, scope: "coach"
      }, headers: headers, as: :json
      token = response.parsed_body.fetch("upload_token")
    end
    intent = CoachContentSource.find(
      Rails.application.message_verifier(:coach_content_source_direct_upload).verify(token).deep_symbolize_keys.fetch(:source_id)
    )
    workspace.coach_workspace_memberships.find_by!(user: coach).destroy!
    clear_enqueued_jobs

    with_singleton_method(S3Service, :configured?, -> { true }) do
      assert_enqueued_with(job: CoachContentSourceUploadExpiryJob, args: [ intent.id ]) do
        post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: headers, as: :json
      end
    end

    assert_response :forbidden
    assert_equal "upload_cleanup", intent.reload.status
  end

  test "platform upload completion fails closed and cleans the intent after an admin is demoted" do
    admin = persona_user(role: "admin")
    checksum = Digest::SHA256.hexdigest("guide")

    token = nil
    with_presign_grant do
      post "/api/v1/admin/content_sources/presign", params: {
        filename: "platform-guide.txt", content_type: "text/plain", byte_size: 5,
        checksum_sha256: checksum, upload_request_id: SecureRandom.uuid, scope: "platform"
      }, headers: auth_headers(admin), as: :json
      token = response.parsed_body.fetch("upload_token")
    end
    assert_response :success
    intent = CoachContentSource.find(
      Rails.application.message_verifier(:coach_content_source_direct_upload).verify(token).deep_symbolize_keys.fetch(:source_id)
    )
    admin.update!(role: "coach")
    clear_enqueued_jobs

    with_singleton_method(S3Service, :configured?, -> { true }) do
      assert_enqueued_with(job: CoachContentSourceUploadExpiryJob, args: [ intent.id ]) do
        post "/api/v1/admin/content_sources/complete", params: { upload_token: token }, headers: auth_headers(admin), as: :json
      end
    end

    assert_response :forbidden
    assert_equal "content_source_forbidden", response.parsed_body.fetch("code")
    assert_equal "upload_cleanup", intent.reload.status
    assert_no_enqueued_jobs only: CoachContentSourceProcessingJob
  end

  test "candidate edit safety failures return the persisted candidate for correction" do
    coach = persona_user
    source, candidate = reviewable_candidate(owner: coach)

    patch "/api/v1/admin/content_sources/#{source.id}/candidates/#{candidate.id}", params: {
      candidate: {
        title: "Private instruction", kind: "guidance", content: "Contact jane@example.com for help.", topics: [],
        revision: candidate.revision, digest: candidate.content_digest
      }
    }, headers: auth_headers(coach), as: :json

    assert_response :unprocessable_entity
    assert_equal "personal_information", response.parsed_body.fetch("code")
    returned = response.parsed_body.fetch("candidate")
    assert_equal "personal_information", returned.fetch("safety_code")
    assert_equal "Contact jane@example.com for help.", returned.fetch("content")
    assert_equal candidate.revision + 1, returned.fetch("revision")
  end

  test "source index omits deleted history so active sources are not crowded out" do
    coach = persona_user
    active = content_source(owner: coach)
    deleted = content_source(owner: coach)
    deleted.update_columns(status: "source_deleted", source_deleted_at: Time.current, s3_key: nil)

    get "/api/v1/admin/content_sources", headers: auth_headers(coach)

    assert_response :success
    assert_equal [ active.id ], response.parsed_body.fetch("sources").map { |source| source.fetch("id") }
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

  test "only administrators see and sweep terminal upload cleanup failures" do
    coach = persona_user
    admin = persona_user(role: "admin")
    source = upload_intent(owner: coach, key: "test/opaque/terminal-cleanup")
    source.update!(status: "upload_cleanup_failed", error_code: "upload_cleanup_failed", error_message: "Private storage cleanup needs an administrator to retry it.")

    get "/api/v1/admin/content_sources", headers: auth_headers(coach)
    assert_response :success
    assert_empty response.parsed_body.fetch("sources")

    get "/api/v1/admin/content_sources", headers: auth_headers(admin)
    assert_response :success
    assert_equal [ source.id ], response.parsed_body.fetch("sources").map { |entry| entry.fetch("id") }

    post "/api/v1/admin/content_sources/retry_upload_cleanups", headers: auth_headers(coach), as: :json
    assert_response :forbidden
    assert_equal "upload_cleanup_failed", source.reload.status

    assert_enqueued_with(job: CoachContentSourceUploadExpiryJob, args: [ source.id, { admin_retry: true } ]) do
      post "/api/v1/admin/content_sources/retry_upload_cleanups", headers: auth_headers(admin), as: :json
    end
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("retried_count")
    assert_equal "upload_cleanup_failed", source.reload.status
  end

  test "reprocess accepts a stale processing source and rejects a recent active attempt" do
    coach = persona_user
    source = content_source(owner: coach)
    attempt = source.attempts.create!(
      generation: 1, provider: "openrouter", model: "test-model", prompt_version: "v1",
      schema_version: "v1", status: "processing", started_at: 20.minutes.ago
    )
    source.update!(status: "processing", generation: 1, current_attempt: attempt)

    post "/api/v1/admin/content_sources/#{source.id}/reprocess", headers: auth_headers(coach), as: :json
    assert_response :unprocessable_entity
    assert_equal "processing", source.reload.status

    source.update_column(:updated_at, 16.minutes.ago)
    assert_enqueued_with(job: CoachContentSourceProcessingJob, args: [ source.id ]) do
      post "/api/v1/admin/content_sources/#{source.id}/reprocess", headers: auth_headers(coach), as: :json
    end

    assert_response :success
    assert_equal "queued", source.reload.status
  end

  test "failed upload cleanup stays durable when retry enqueue fails" do
    admin = persona_user(role: "admin")
    source = upload_intent(owner: admin, key: "test/opaque/enqueue-failure", scope: "platform")
    source.update!(status: "upload_cleanup_failed", error_code: "upload_cleanup_failed", error_message: "Cleanup needs retry.")

    with_singleton_method(CoachContentSourceUploadExpiryJob, :perform_later, ->(*) { raise ActiveJob::EnqueueError, "adapter unavailable" }) do
      post "/api/v1/admin/content_sources/retry_upload_cleanups", headers: auth_headers(admin), as: :json
    end

    assert_response :service_unavailable
    assert_equal "upload_cleanup_retry_unavailable", response.parsed_body.fetch("code")
    assert_equal "upload_cleanup_failed", source.reload.status
    assert source.s3_key.present?
  end

  test "old terminal upload cleanup remains visible ahead of one hundred newer sources" do
    admin = persona_user(role: "admin")
    failed = upload_intent(owner: admin, key: "test/opaque/old-terminal", scope: "platform")
    failed.update!(status: "upload_cleanup_failed", error_code: "upload_cleanup_failed", error_message: "Cleanup needs retry.")
    failed.update_column(:created_at, 2.days.ago)
    100.times { content_source(owner: admin) }

    get "/api/v1/admin/content_sources", headers: auth_headers(admin)

    assert_response :success
    listed_ids = response.parsed_body.fetch("sources").map { |entry| entry.fetch("id") }
    assert_equal 100, listed_ids.length
    assert_includes listed_ids, failed.id
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

  def workspace_auth_headers(user, workspace)
    auth_headers(user).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
  end
end
