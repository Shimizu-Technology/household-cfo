# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminCoachContentSourceUrlIntakesControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper
  include ActiveJob::TestHelper

  test "coach creates one encrypted workspace intake and an identical retry is idempotent" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    request_id = SecureRandom.uuid

    with_storage_configured do
      assert_enqueued_with(job: CoachContentSourceUrlIntakeJob) do
        post endpoint, params: {
          url: "https://example.com/Mrs-Mel-guide?private=canary",
          request_id: request_id,
          scope: "coach"
        }, headers: workspace_auth_headers(coach, workspace), as: :json
      end
    end

    assert_response :accepted
    assert_equal true, response.parsed_body.dig("url_intake", "enabled")
    assert_equal true, response.parsed_body.dig("url_intake", "available")
    intake = CoachContentSourceUrlIntake.find(response.parsed_body.dig("intake", "id"))
    assert_equal workspace, intake.coach_workspace
    assert_equal "queued", intake.status
    assert_nil intake.coach_content_source
    refute_includes intake.attributes.values.compact.join(" "), "Mrs-Mel"
    refute_includes response.body, "private=canary"
    assert_equal "https://example.com/Mrs-Mel-guide?private=canary", ContentSources::UrlCipher.decrypt(intake.encrypted_url_payload)

    get endpoint, headers: workspace_auth_headers(coach, workspace)
    assert_response :success
    assert_equal [ intake.id ], response.parsed_body.fetch("intakes").map { |entry| entry.fetch("id") }
    refute_includes response.body, "Mrs-Mel"
    refute_includes response.body, "private=canary"

    assert_no_difference -> { CoachContentSourceUrlIntake.count } do
      with_storage_configured do
        post endpoint, params: {
          url: "https://example.com/Mrs-Mel-guide?private=canary",
          request_id: request_id,
          scope: "coach"
        }, headers: workspace_auth_headers(coach, workspace), as: :json
      end
    end
    assert_response :success
  end

  test "disabled feature is exposed and rejects creation without evaluating secure keys" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    previous = Rails.application.config.x.content_source_url_intake_enabled
    Rails.application.config.x.content_source_url_intake_enabled = false

    get endpoint, headers: workspace_auth_headers(coach, workspace)
    assert_response :success
    assert_equal({ "enabled" => false, "available" => false }, response.parsed_body.fetch("url_intake"))

    assert_no_difference -> { CoachContentSourceUrlIntake.count } do
      post endpoint, params: { url: "https://example.com/guide", request_id: SecureRandom.uuid },
        headers: workspace_auth_headers(coach, workspace), as: :json
    end
    assert_response :service_unavailable
    assert_equal "url_intake_disabled", response.parsed_body.fetch("code")
  ensure
    Rails.application.config.x.content_source_url_intake_enabled = previous
  end

  test "retry identity uses the version stored with the intake across HMAC rotation" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    url = "https://example.com/rotation-safe"
    request_id = SecureRandom.uuid
    encrypted = ContentSources::UrlCipher.encrypt(url)
    intake = CoachContentSourceUrlIntake.create!(
      scope: "coach", coach_workspace: workspace, created_by_user: coach, request_id: request_id,
      encrypted_url_ciphertext: encrypted.fetch(:ciphertext), encrypted_url_iv: encrypted.fetch(:iv),
      encrypted_url_auth_tag: encrypted.fetch(:auth_tag), encryption_key_version: encrypted.fetch(:key_version),
      url_identity_hmac: ContentSources::UrlCipher.identity(url, version: 1), hmac_key_version: 1,
      status: "failed", reserved_bytes: CoachContentSourceUrlIntakeJob::RESERVATION_BYTES
    )

    with_singleton_method(ContentSources::UrlCipher, :current_version, -> { 2 }) do
      with_storage_configured do
        assert_no_difference -> { CoachContentSourceUrlIntake.count } do
          post endpoint, params: { url: url, request_id: request_id },
            headers: workspace_auth_headers(coach, workspace), as: :json
        end
      end
    end

    assert_response :success
    assert_equal intake.id, response.parsed_body.dig("intake", "id")
    assert_equal 1, intake.reload.hmac_key_version
    assert_equal "queued", intake.status
  end

  test "request id cannot be replayed for a different private address" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    request_id = SecureRandom.uuid

    with_storage_configured do
      post endpoint, params: { url: "https://example.com/first", request_id: request_id },
        headers: workspace_auth_headers(coach, workspace), as: :json
      post endpoint, params: { url: "https://example.com/second", request_id: request_id },
        headers: workspace_auth_headers(coach, workspace), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "url_intake_conflict", response.parsed_body.fetch("code")
    assert_equal 1, CoachContentSourceUrlIntake.count
  end

  test "upload and URL intake request identities cannot collide" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    upload_request_id = SecureRandom.uuid
    CoachContentSource.create!(
      scope: "coach", coach_workspace: workspace, created_by_user: coach, status: "uploading",
      filename: "guide.txt", content_type: "text/plain", byte_size: 5,
      checksum_sha256: Digest::SHA256.hexdigest("guide"), s3_key: "test/#{SecureRandom.uuid}",
      upload_request_id: upload_request_id
    )

    with_storage_configured do
      post endpoint, params: { url: "https://example.com/guide", request_id: upload_request_id },
        headers: workspace_auth_headers(coach, workspace), as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "url_intake_conflict", response.parsed_body.fetch("code")

    url_request_id = SecureRandom.uuid
    with_storage_configured do
      post endpoint, params: { url: "https://example.com/guide", request_id: url_request_id },
        headers: workspace_auth_headers(coach, workspace), as: :json
      post "/api/v1/admin/content_sources/presign", params: {
        filename: "guide.txt", content_type: "text/plain", byte_size: 5,
        checksum_sha256: Digest::SHA256.hexdigest("guide"), upload_request_id: url_request_id, scope: "coach"
      }, headers: workspace_auth_headers(coach, workspace), as: :json
    end
    assert_response :unprocessable_entity
    assert_equal "upload_conflict", response.parsed_body.fetch("code")
  end

  test "viewer and participant cannot create or inspect workspace URL intakes" do
    owner = persona_user
    viewer = persona_user
    participant = persona_user(role: "participant")
    workspace = CoachWorkspaces::Resolver.new(user: owner).call
    workspace.coach_workspace_memberships.create!(user: viewer, role: "viewer")

    with_storage_configured do
      post endpoint, params: { url: "https://example.com/guide", request_id: SecureRandom.uuid },
        headers: workspace_auth_headers(viewer, workspace), as: :json
    end
    assert_response :forbidden

    post endpoint, params: { url: "https://example.com/guide", request_id: SecureRandom.uuid },
      headers: auth_headers(participant), as: :json
    assert_response :forbidden
  end

  test "URL reservation shares source count quota with uploads" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    100.times do |index|
      CoachContentSource.create!(
        scope: "coach", coach_workspace: workspace, created_by_user: coach, status: "queued",
        filename: "#{index}.txt", content_type: "text/plain", byte_size: 1,
        checksum_sha256: Digest::SHA256.hexdigest(index.to_s), s3_key: "test/#{SecureRandom.uuid}",
        upload_request_id: SecureRandom.uuid
      )
    end
    CoachContentSource.update_all(created_at: 1.day.ago)

    with_storage_configured do
      post endpoint, params: { url: "https://example.com/guide", request_id: SecureRandom.uuid },
        headers: workspace_auth_headers(coach, workspace), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "source_quota_reached", response.parsed_body.fetch("code")
    assert_empty CoachContentSourceUrlIntake.all
  end

  test "only an administrator can retry terminal URL object cleanup" do
    admin = persona_user(role: "admin")
    coach = persona_user
    encrypted = ContentSources::UrlCipher.encrypt("https://example.com/guide")
    intake = CoachContentSourceUrlIntake.create!(
      scope: "platform", created_by_user: admin, request_id: SecureRandom.uuid,
      encrypted_url_ciphertext: encrypted.fetch(:ciphertext), encrypted_url_iv: encrypted.fetch(:iv),
      encrypted_url_auth_tag: encrypted.fetch(:auth_tag), encryption_key_version: 1,
      url_identity_hmac: ContentSources::UrlCipher.identity("https://example.com/guide"), hmac_key_version: 1,
      status: "cleanup_failed", reserved_bytes: CoachContentSourceUrlIntakeJob::RESERVATION_BYTES,
      staging_s3_key: "staging/#{SecureRandom.uuid}", cleanup_attempts: 5
    )

    post "#{endpoint}/#{intake.id}/retry_cleanup", headers: auth_headers(coach), as: :json
    assert_response :not_found

    assert_enqueued_with(job: CoachContentSourceUrlCleanupJob, args: [ intake.id ]) do
      post "#{endpoint}/#{intake.id}/retry_cleanup", headers: auth_headers(admin), as: :json
    end
    assert_response :accepted
    assert_equal true, response.parsed_body.dig("intake", "cleanup_retryable")
  end

  test "an editor can redact a terminal unregistered intake without exposing its address" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    secret_url = "https://example.com/private?secret=delete-me"
    encrypted = ContentSources::UrlCipher.encrypt(secret_url)
    intake = CoachContentSourceUrlIntake.create!(
      scope: "coach", coach_workspace: workspace, created_by_user: coach, request_id: SecureRandom.uuid,
      encrypted_url_ciphertext: encrypted.fetch(:ciphertext), encrypted_url_iv: encrypted.fetch(:iv),
      encrypted_url_auth_tag: encrypted.fetch(:auth_tag), encryption_key_version: 1,
      url_identity_hmac: ContentSources::UrlCipher.identity(secret_url), hmac_key_version: 1,
      status: "failed", error_code: "url_fetch_failed",
      reserved_bytes: CoachContentSourceUrlIntakeJob::RESERVATION_BYTES, completed_at: Time.current
    )

    delete "#{endpoint}/#{intake.id}", headers: workspace_auth_headers(coach, workspace), as: :json

    assert_response :success
    intake.reload
    assert_equal "deleted", intake.status
    assert_nil intake.encrypted_url_ciphertext
    assert intake.redaction_requested_at.present?
    refute_includes response.body, "delete-me"
  end

  test "cleanup-backed redaction is queued and hidden from subsequent listings" do
    coach = persona_user
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    intake = terminal_intake(coach:, workspace:, status: "cleanup_failed", staging_s3_key: "staging/#{SecureRandom.uuid}")

    assert_enqueued_with(job: CoachContentSourceUrlCleanupJob, args: [ intake.id ]) do
      delete "#{endpoint}/#{intake.id}", headers: workspace_auth_headers(coach, workspace), as: :json
    end

    assert_response :accepted
    assert_equal "cleanup_pending", intake.reload.status
    assert intake.redaction_pending?
    assert_nil intake.encrypted_url_ciphertext
    get endpoint, headers: workspace_auth_headers(coach, workspace)
    assert_equal [ intake.id ], response.parsed_body.fetch("intakes").map { |entry| entry.fetch("id") }
    assert_equal true, response.parsed_body.dig("intakes", 0, "redaction_pending")
  end

  private

  def endpoint
    "/api/v1/admin/content_source_url_intakes"
  end

  def with_storage_configured(&block)
    with_singleton_method(S3Service, :configured?, -> { true }, &block)
  end

  def terminal_intake(coach:, workspace:, status:, staging_s3_key: nil)
    url = "https://example.com/private/#{SecureRandom.hex(4)}"
    encrypted = ContentSources::UrlCipher.encrypt(url)
    CoachContentSourceUrlIntake.create!(
      scope: "coach", coach_workspace: workspace, created_by_user: coach, request_id: SecureRandom.uuid,
      encrypted_url_ciphertext: encrypted.fetch(:ciphertext), encrypted_url_iv: encrypted.fetch(:iv),
      encrypted_url_auth_tag: encrypted.fetch(:auth_tag), encryption_key_version: 1,
      url_identity_hmac: ContentSources::UrlCipher.identity(url), hmac_key_version: 1,
      status: status, reserved_bytes: CoachContentSourceUrlIntakeJob::RESERVATION_BYTES,
      staging_s3_key: staging_s3_key, completed_at: Time.current
    )
  end

  def with_singleton_method(target, name, implementation)
    original = target.method(name)
    target.define_singleton_method(name, implementation)
    yield
  ensure
    target.define_singleton_method(name, original)
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def workspace_auth_headers(user, workspace)
    auth_headers(user).merge("X-Coach-Workspace-Id" => workspace.id.to_s)
  end
end
