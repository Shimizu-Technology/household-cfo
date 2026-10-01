# frozen_string_literal: true

class CoachContentSourceProcessingJob < ApplicationJob
  queue_as :default

  STALE_PROCESSING_AFTER = 15.minutes
  MAX_CANDIDATES = 30

  def perform(source_id)
    source = CoachContentSource.find_by(id: source_id)
    return unless source

    parser = ContentSources::Parser.new
    proposer = ContentSources::CandidateProposer.new
    attempt = begin_attempt!(source, proposer)
    return unless attempt

    result, proposal_metadata = process_source(source, parser: parser, proposer: proposer)
    persist_success!(source, attempt, result, proposal_metadata)
  rescue ContentSources::Error => error
    persist_failure_safely(source, attempt, error) if defined?(source) && source
  rescue StandardError => error
    Rails.logger.warn("[CoachContentSourceProcessingJob] source=#{source_id} error_class=#{error.class}")
    persist_failure_safely(source, attempt, ContentSources::Error.new("processing_failed")) if defined?(source) && source
  end

  private

  def begin_attempt!(source, proposer)
    source.with_lock do
      return if source.status.in?(%w[deletion_pending deletion_failed source_deleted]) || source.source_deleted_at.present?
      stale_processing = source.status == "processing" && source.updated_at <= STALE_PROCESSING_AFTER.ago
      return unless source.status == "queued" || stale_processing
      if source.status == "processing" && source.current_attempt&.status == "processing" && source.updated_at > STALE_PROCESSING_AFTER.ago
        return
      end

      supersede_current_attempt!(source)
      source.candidates.where(status: "proposed").update_all(status: "superseded", updated_at: Time.current)
      next_generation = source.generation + 1
      attempt = source.attempts.create!(
        generation: next_generation,
        provider: "openrouter",
        model: proposer.model,
        prompt_version: ContentSources::CandidateProposer::PROMPT_VERSION,
        schema_version: ContentSources::CandidateProposer::SCHEMA_VERSION,
        status: "processing",
        started_at: Time.current
      )
      source.update!(
        generation: next_generation,
        current_attempt: attempt,
        status: "processing",
        error_code: nil,
        error_message: nil,
        processed_at: nil,
        processing_metadata: {}
      )
      attempt
    end
  end

  def process_source(source, parser:, proposer:)
    raise ContentSources::Error, "source_deleted" unless source.reload.source_available?

    tempfile = Tempfile.new([ "coach_content_source_#{source.id}", safe_extension(source.filename) ])
    tempfile.binmode
    S3Service.download_to_io!(source.s3_key, tempfile)
    tempfile.close
    parsed = parser.call(path: tempfile.path, filename: source.filename)
    candidates = []
    usage = Hash.new(0)
    parsed.segments.each do |segment|
      proposed = proposer.call(segment)
      candidates.concat(proposed.candidates)
      proposed.metadata.fetch("usage", {}).each { |key, value| usage[key] += value if value.is_a?(Numeric) }
    end
    candidates = candidates.uniq(&:content_digest)
    raise ContentSources::Error, "proposal_limit" if candidates.length > MAX_CANDIDATES
    [
      { parsed: parsed, candidates: candidates },
      { "usage" => usage.presence, "candidate_count" => candidates.length }.compact
    ]
  rescue Aws::S3::Errors::ServiceError, S3Service::MissingConfigurationError
    raise ContentSources::Error, "storage_unavailable"
  ensure
    tempfile&.close!
  end

  def persist_success!(source, attempt, result, proposal_metadata)
    source.with_lock do
      unless authoritative?(source, attempt)
        supersede_attempt!(attempt)
        return
      end

      attempt.candidates.delete_all
      result.fetch(:candidates).each_with_index do |candidate, position|
        attempt.candidates.create!(
          coach_content_source: source,
          position: position,
          status: "proposed",
          title: candidate.title,
          kind: candidate.kind,
          content: candidate.content,
          topics: candidate.topics,
          evidence_locator: candidate.evidence_locator,
          evidence_excerpt: candidate.evidence_excerpt,
          content_digest: candidate.content_digest,
          revision: 1
        )
      end
      parsed = result.fetch(:parsed)
      attempt.update!(status: "succeeded", completed_at: Time.current, metadata: proposal_metadata)
      source.update!(
        status: "needs_review",
        processed_at: Time.current,
        processing_metadata: parsed.metadata.stringify_keys.slice("format", "page_count", "paragraph_count", "line_count", "cue_count", "character_count", "segment_count").merge(
          "candidate_count" => result.fetch(:candidates).length
        ),
        error_code: nil,
        error_message: nil
      )
    end
  end

  def persist_failure_safely(source, attempt, error)
    source.with_lock do
      unless authoritative?(source, attempt)
        supersede_attempt!(attempt)
        return
      end

      attempt.update!(
        status: "failed",
        error_code: error.code,
        error_message: error.message,
        completed_at: Time.current,
        metadata: {}
      )
      source.update!(
        status: "failed",
        error_code: error.code,
        error_message: error.message,
        processed_at: Time.current,
        processing_metadata: {}
      )
    end
  rescue StandardError => persistence_error
    Rails.logger.warn("[CoachContentSourceProcessingJob] source=#{source&.id} failure_persist_class=#{persistence_error.class}")
  end

  def authoritative?(source, attempt)
    attempt&.reload&.status == "processing" && source.status == "processing" &&
      source.current_attempt_id == attempt.id && source.generation == attempt.generation &&
      source.source_deleted_at.blank? && source.deletion_requested_at.blank?
  end

  def supersede_current_attempt!(source)
    attempt = source.current_attempt
    return unless attempt&.status == "processing"

    attempt.update!(status: "superseded", error_code: "superseded", error_message: "A newer processing attempt replaced this one.", completed_at: Time.current)
  end

  def supersede_attempt!(attempt)
    return unless attempt&.reload&.status == "processing"

    attempt.update!(status: "superseded", error_code: "superseded", error_message: "A newer source state replaced this attempt.", completed_at: Time.current)
  end

  def safe_extension(filename)
    extension = File.extname(filename.to_s).downcase
    ContentSources::UploadValidator::EXTENSIONS.include?(extension) ? extension : ".bin"
  end
end
