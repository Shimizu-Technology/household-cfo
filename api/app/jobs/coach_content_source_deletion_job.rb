# frozen_string_literal: true

class CoachContentSourceDeletionJob < ApplicationJob
  queue_as :default

  MAX_AUTOMATIC_ATTEMPTS = 5
  DeletionPlan = Data.define(:source_key, :keys)

  def perform(source_id)
    source = CoachContentSource.find_by(id: source_id)
    return unless source

    plan = prepare_deletion!(source)
    return if plan == :skip

    plan.keys.each { |key| S3Service.delete!(key) }
    finalize_deletion!(source, plan.source_key)
  rescue Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError => error
    Rails.logger.warn("[CoachContentSourceDeletionJob] source=#{source_id} error_class=#{error.class}")
    persist_deletion_failure!(source) if defined?(source) && source
  end

  private

  def prepare_deletion!(source)
    source.with_lock do
      return :skip if source.status == "source_deleted"
      return :skip unless source.status.in?(%w[deletion_pending deletion_failed])

      staging_key = source.url_intake&.staging_s3_key
      keys = [ source.s3_key, staging_key ].compact.uniq
      if keys.any?
        metadata = source.processing_metadata.to_h.slice("format", "page_count", "paragraph_count", "line_count", "cue_count", "character_count", "segment_count", "candidate_count")
        metadata["delete_attempts"] = source.processing_metadata.to_h.fetch("delete_attempts", 0).to_i + 1
        source.update!(status: "deletion_pending", source_delete_error_code: nil, processing_metadata: metadata)
      end

      DeletionPlan.new(source_key: source.s3_key, keys: keys)
    end
  end

  def finalize_deletion!(source, key)
    source.with_lock do
      return unless source.s3_key == key && source.status == "deletion_pending"

      now = Time.current
      source.candidates.find_each do |candidate|
        attributes = {
          evidence_excerpt: "[removed after source deletion]",
          safety_code: "source_deleted",
          updated_at: now
        }
        unless candidate.status == "accepted"
          attributes.merge!(
            status: "superseded",
            title: "Removed after source deletion",
            content: "Removed after source deletion.",
            topics: [],
            content_digest: CoachContentSourceCandidate.digest_for(
              title: "Removed after source deletion",
              kind: candidate.kind,
              content: "Removed after source deletion.",
              topics: []
            )
          )
        end
        candidate.update_columns(attributes)
      end
      source.update!(
        status: "source_deleted",
        s3_key: nil,
        source_deleted_at: now,
        source_delete_error_code: nil,
        error_code: nil,
        error_message: nil
      )
      source.update_column(:filename, CoachContentItemDraftProvenance.provenance_filename_for(source.filename))
      source.url_intake&.update_columns(
        status: "deleted",
        encrypted_url_ciphertext: nil,
        encrypted_url_iv: nil,
        encrypted_url_auth_tag: nil,
        staging_s3_key: nil,
        final_s3_key: nil,
        completed_at: now,
        updated_at: now
      )
    end
  end

  def persist_deletion_failure!(source)
    attempts = 0
    source.with_lock do
      return if source.status == "source_deleted"

      attempts = source.processing_metadata.to_h.fetch("delete_attempts", 0).to_i
      source.update!(status: "deletion_failed", source_delete_error_code: "storage_unavailable")
    end
    self.class.set(wait: (attempts * 2).minutes).perform_later(source.id) if attempts < MAX_AUTOMATIC_ATTEMPTS
  rescue StandardError => persistence_error
    Rails.logger.warn("[CoachContentSourceDeletionJob] source=#{source&.id} failure_persist_class=#{persistence_error.class}")
  end
end
