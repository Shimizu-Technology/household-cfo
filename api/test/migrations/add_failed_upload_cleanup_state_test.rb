# frozen_string_literal: true

require "test_helper"
require_relative "../../db/migrate/20261001073000_add_failed_upload_cleanup_state"
require_relative "../support/persona_test_helper"

class AddFailedUploadCleanupStateTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "rollback maps terminal cleanup failures to the older durable cleanup state" do
    owner = persona_user(role: "admin")
    source = CoachContentSource.create!(
      scope: "platform",
      created_by_user: owner,
      status: "upload_cleanup_failed",
      filename: "uploaded-source.txt",
      content_type: "text/plain",
      byte_size: 5,
      checksum_sha256: Digest::SHA256.hexdigest("guide"),
      s3_key: "test/migration/#{SecureRandom.uuid}",
      upload_request_id: SecureRandom.uuid,
      error_code: "upload_cleanup_failed",
      error_message: "Private storage cleanup needs an administrator to retry it."
    )
    migration = AddFailedUploadCleanupState.new
    migrated_down = false

    migration.migrate(:down)
    migrated_down = true
    assert_equal "upload_cleanup", source.reload.status

    migration.migrate(:up)
    migrated_down = false
    source.update!(status: "upload_cleanup_failed")
    assert_equal "upload_cleanup_failed", source.reload.status
  ensure
    migration&.migrate(:up) if migrated_down
  end
end
