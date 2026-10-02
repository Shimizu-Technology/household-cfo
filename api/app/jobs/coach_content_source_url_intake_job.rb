# frozen_string_literal: true

require "base64"

class CoachContentSourceUrlIntakeJob < ApplicationJob
  queue_as :default

  RESERVATION_BYTES = ContentSources::UploadValidator::PDF_MAX_BYTES

  def perform(intake_id)
    intake = CoachContentSourceUrlIntake.find_by(id: intake_id)
    return unless intake

    url = claim_fetch!(intake)
    return unless url

    result = ContentSources::FetchSandbox.new.call(url)
    stage!(intake, result)
    register!(intake)
  rescue ContentSources::Error => error
    fail_safely(intake, error.code) if defined?(intake) && intake
  rescue ContentSources::UrlCipher::DecryptionError, ContentSources::UrlCipher::ConfigurationError
    fail_safely(intake, "url_intake_unavailable") if defined?(intake) && intake
  rescue Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError
    fail_safely(intake, "storage_unavailable", cleanup: true) if defined?(intake) && intake
  rescue StandardError => error
    Rails.logger.warn("[CoachContentSourceUrlIntakeJob] intake=#{intake_id} error_class=#{error.class}")
    fail_safely(intake, "url_fetch_failed", cleanup: true) if defined?(intake) && intake
  ensure
    result&.close!
  end

  private

  def claim_fetch!(intake)
    payload = nil
    intake.with_lock do
      return if intake.status == "registered"
      return unless intake.status.in?(%w[queued failed])
      unless current_permission?(intake)
        intake.update!(status: "failed", error_code: "url_intake_unavailable", completed_at: Time.current)
        return
      end

      intake.update!(status: "fetching", error_code: nil, completed_at: nil)
      payload = intake.encrypted_url_payload
    end
    ContentSources::UrlCipher.decrypt(payload)
  end

  def stage!(intake, result)
    key = S3Service.namespaced_key("coach_content_source_url_staging", intake.id, SecureRandom.uuid, "snapshot")
    intake.with_lock do
      raise ContentSources::Error, "url_intake_conflict" unless intake.status == "fetching"
      intake.update!(staging_s3_key: key)
    end
    S3Service.upload_file!(
      key, result.path, content_type: result.content_type, checksum_sha256: result.checksum_sha256
    )
    intake.with_lock do
      raise ContentSources::Error, "url_intake_conflict" unless intake.status == "fetching"
      intake.update!(
        status: "staged",
        resolved_filename: result.filename,
        resolved_content_type: result.content_type,
        fetched_byte_size: result.byte_size,
        fetched_checksum_sha256: result.checksum_sha256,
        redirect_count: result.redirect_count,
        fetched_at: Time.current
      )
    end
  end

  def register!(intake)
    raise ContentSources::Error, "url_intake_unavailable" unless current_permission?(intake)

    destination = S3Service.namespaced_key(
      "coach_content_sources", intake.created_by_user_id, SecureRandom.uuid, "url-snapshot"
    )
    intake.with_lock do
      raise ContentSources::Error, "url_intake_conflict" unless intake.status == "staged"
      intake.update!(status: "registering", final_s3_key: destination)
    end
    S3Service.copy!(intake.staging_s3_key, destination)
    verify_final_object!(intake, destination)

    quota = quota_for(intake)
    ContentSources::OwnerLock.call("upload-quota:#{quota.owner_key}") do
      intake.lock!
      raise ContentSources::Error, "url_intake_conflict" unless intake.status == "registering"
      raise ContentSources::Error, "url_intake_unavailable" unless current_permission?(intake)

      quota.enforce!(requested_bytes: intake.fetched_byte_size, exclude_intake: intake)
      source = CoachContentSource.create!(
        scope: intake.scope,
        coach_workspace: intake.coach_workspace,
        created_by_user: intake.created_by_user,
        status: "queued",
        ingestion_method: "url_snapshot",
        filename: intake.resolved_filename,
        content_type: intake.resolved_content_type,
        byte_size: intake.fetched_byte_size,
        checksum_sha256: intake.fetched_checksum_sha256,
        s3_key: destination,
        upload_request_id: intake.request_id
      )
      intake.update!(
        status: "registered", coach_content_source: source, completed_at: Time.current,
        reserved_bytes: intake.fetched_byte_size, error_code: nil
      )
    end
    begin
      S3Service.delete!(intake.staging_s3_key)
      intake.update_column(:staging_s3_key, nil)
    rescue Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError
      CoachContentSourceUrlCleanupJob.perform_later(intake.id)
    end
    CoachContentSourceProcessingJob.perform_later(intake.coach_content_source_id)
  rescue StandardError
    schedule_cleanup!(intake)
    raise
  end

  def current_permission?(intake)
    user = User.find_by(id: intake.created_by_user_id)
    return false unless user&.staff?

    workspace = intake.scope == "coach" ? CoachWorkspace.find_by(id: intake.coach_workspace_id) : nil
    if workspace
      CoachWorkspaceMembership.where(coach_workspace: workspace, user: user).lock.load if ApplicationRecord.connection.transaction_open?
    end
    Mia::ContentLibraryPolicy.new(user, workspace: workspace).can_upload_source?(intake.scope)
  end

  def verify_final_object!(intake, key)
    object = S3Service.object_metadata(key)
    expected_checksum = Base64.strict_encode64([ intake.fetched_checksum_sha256 ].pack("H*"))
    valid = object &&
      object.fetch(:byte_size).to_i == intake.fetched_byte_size &&
      object.fetch(:content_type).to_s == intake.resolved_content_type &&
      object.fetch(:server_side_encryption).to_s == "AES256" &&
      ActiveSupport::SecurityUtils.secure_compare(object.fetch(:checksum_sha256).to_s, expected_checksum)
    raise ContentSources::Error, "signature_mismatch" unless valid
  end

  def quota_for(intake)
    ContentSources::Quota.new(
      scope: intake.scope, user: intake.created_by_user, workspace: intake.coach_workspace
    )
  end

  def fail_safely(intake, code, cleanup: false)
    intake.with_lock do
      return if intake.status.in?(%w[registered deleted])

      needs_cleanup = cleanup || intake.staging_s3_key.present? || intake.final_s3_key.present?
      intake.update!(
        status: needs_cleanup ? "cleanup_pending" : "failed",
        error_code: code,
        completed_at: Time.current
      )
    end
    schedule_cleanup!(intake) if intake.status == "cleanup_pending"
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def schedule_cleanup!(intake)
    intake.with_lock do
      return if intake.status.in?(%w[deleted cleanup_pending cleanup_failed])
      if intake.status == "registered"
        CoachContentSourceUrlCleanupJob.perform_later(intake.id) if intake.staging_s3_key.present?
        return
      end
      intake.update!(status: "cleanup_pending")
    end
    CoachContentSourceUrlCleanupJob.perform_later(intake.id)
  end
end
