# frozen_string_literal: true

class FinancialDocumentExtractionJob < ApplicationJob
  queue_as :default

  ATTEMPT_METADATA_STRING_LENGTH = 120
  ATTEMPT_USAGE_KEYS = %w[prompt_tokens completion_tokens total_tokens].freeze
  EXTRACTION_SUCCESS_METADATA_KEYS = %w[confidence warnings extraction_model extraction_mode extraction_page_count extraction_batch_count last_extracted_at transaction_draft_count transaction_match_count routing_detected_kind routing_resolved_kind routing_source routing_conflict routing_requires_confirmation routing_destination].freeze
  STALE_PROCESSING_AFTER = 15.minutes

  def perform(financial_document_import_id)
    document_import = FinancialDocumentImport.find_by(id: financial_document_import_id)
    return unless document_import
    return if document_import.source_deleted_at.present?

    extractor = FinancialDocuments::Extractor.new
    attempt = nil

    document_import.with_lock do
      return if document_import.source_deleted_at.present?
      unless extraction_startable?(document_import)
        schedule_stale_processing_recheck!(document_import) if document_import.status == "processing"
        return
      end

      mark_stale_processing_attempts!(document_import) if stale_processing?(document_import)
      attempt = document_import.attempts.create!(
        provider: "openrouter",
        model: extractor.model,
        status: "processing",
        prompt_version: FinancialDocuments::Extractor::PROMPT_VERSION,
        schema_version: FinancialDocuments::Extractor::SCHEMA_VERSION,
        started_at: Time.current
      )
      document_import.update!(status: "processing", extraction_error: nil)
    end

    result = extractor.call(document_import.reload)
    if result.success?
      persist_success!(document_import, attempt, result)
    else
      persist_failure!(document_import, attempt, result.error, result.metadata)
    end
  rescue StandardError => e
    Rails.logger.error("[FinancialDocumentExtractionJob] import #{financial_document_import_id} failed: #{e.class}: #{e.message}")
    persist_failure_safely(document_import, attempt, e.message) if defined?(document_import) && document_import
  end

  private

  def persist_success!(document_import, attempt, result)
    data = result.data
    document_import.with_lock do
      unless authoritative_attempt?(document_import, attempt)
        mark_attempt_superseded!(attempt)
        return
      end

      routing = FinancialDocuments::RoutingDecision.new(document_import, detected_kind: data[:document_kind]).call
      document_import.document_kind = routing.resolved_kind
      document_import.items.where(applied_at: nil).delete_all
      Array(data[:items]).each do |item_attributes|
        document_import.items.create!(item_attributes)
      end
      draft_result = HouseholdFinance::DocumentTransactionDraftPersister.new(document_import, data[:transaction_drafts]).call
      warnings = Array(data[:warnings]) + Array(draft_result.fetch(:warnings))
      if routing.conflict
        warnings.unshift("You described this as #{routing.resolved_kind.humanize.downcase}, while Mia detected #{routing.detected_kind.humanize.downcase}. Mia kept your description and left every extracted value pending for you to verify.")
      end

      metadata = (document_import.metadata || {}).merge(
        "confidence" => data[:confidence],
        "warnings" => warnings.first(FinancialDocuments::Extractor::MAX_WARNINGS),
        "extraction_model" => attempt.model,
        "extraction_mode" => result.metadata[:extraction_mode],
        "extraction_page_count" => result.metadata[:page_count],
        "extraction_batch_count" => result.metadata[:batch_count],
        "last_extracted_at" => Time.current.iso8601,
        "transaction_draft_count" => draft_result.fetch(:created_count),
        "transaction_match_count" => draft_result.fetch(:match_count),
        "routing_detected_kind" => routing.detected_kind,
        "routing_resolved_kind" => routing.resolved_kind,
        "routing_source" => routing.source,
        "routing_conflict" => routing.conflict,
        "routing_requires_confirmation" => routing.requires_confirmation,
        "routing_destination" => routing.destination
      ).compact

      document_import.update!(
        document_kind: routing.resolved_kind,
        status: "needs_review",
        document_date: data[:document_date],
        period_start_on: data[:period_start_on],
        period_end_on: data[:period_end_on],
        extracted_summary: data[:summary],
        extraction_error: nil,
        processed_at: Time.current,
        metadata: metadata
      )
      HouseholdFinance::DocumentImportStatusReconciler.new(document_import).call

      attempt.update!(
        status: "succeeded",
        completed_at: Time.current,
        metadata: sanitized_attempt_metadata(result.metadata)
      )
    end
  rescue StandardError => e
    persist_failure!(document_import, attempt, e.message, result&.metadata || {})
  end

  def persist_failure!(document_import, attempt, error, metadata = {})
    document_import.with_lock do
      unless authoritative_attempt?(document_import, attempt)
        mark_attempt_superseded!(attempt)
        return
      end

      document_import.update!(
        status: "failed",
        extraction_error: error.to_s.truncate(500, omission: "…"),
        extracted_summary: nil,
        document_date: nil,
        period_start_on: nil,
        period_end_on: nil,
        processed_at: Time.current,
        metadata: extraction_failure_metadata(document_import.metadata)
      )
      attempt&.update!(
        status: "failed",
        error: error.to_s.truncate(1000, omission: "…"),
        completed_at: Time.current,
        metadata: sanitized_attempt_metadata(metadata)
      )
    end
  end

  def extraction_startable?(document_import)
    document_import.status == "uploaded" || stale_processing?(document_import)
  end

  def stale_processing?(document_import)
    document_import.status == "processing" && document_import.updated_at.present? && document_import.updated_at <= STALE_PROCESSING_AFTER.ago
  end

  def schedule_stale_processing_recheck!(document_import)
    wait_seconds = [ (document_import.updated_at + STALE_PROCESSING_AFTER - Time.current).ceil, 60 ].max
    Rails.logger.info("[FinancialDocumentExtractionJob] import #{document_import.id} is already processing; scheduling stale recheck in #{wait_seconds} seconds")
    self.class.set(wait: wait_seconds.seconds).perform_later(document_import.id)
  end

  def mark_stale_processing_attempts!(document_import)
    Rails.logger.warn("[FinancialDocumentExtractionJob] restarting stale processing import #{document_import.id}")
    document_import.attempts.where(status: "processing").find_each do |attempt|
      attempt.update!(
        status: "failed",
        error: "Extraction attempt was abandoned after processing stalled",
        completed_at: Time.current,
        metadata: (attempt.metadata || {}).merge("stalled" => true)
      )
    end
  end

  def extraction_failure_metadata(metadata)
    (metadata || {}).except(*EXTRACTION_SUCCESS_METADATA_KEYS).merge("last_extraction_failed_at" => Time.current.iso8601)
  end

  def persist_failure_safely(document_import, attempt, error)
    persist_failure!(document_import, attempt, error)
  rescue StandardError => failure_error
    Rails.logger.warn("[FinancialDocumentExtractionJob] could not persist failure for import #{document_import&.id}: #{failure_error.class}: #{failure_error.message}")
  end

  def authoritative_attempt?(document_import, attempt)
    return false unless attempt

    attempt.reload
    return false unless attempt.status == "processing"
    return false unless document_import.status == "processing"
    return false if document_import.source_deleted_at.present?

    !document_import.attempts.where("id > ?", attempt.id).exists?
  end

  def mark_attempt_superseded!(attempt)
    return unless attempt

    attempt.reload
    return unless attempt.status == "processing"

    attempt.update!(
      status: "failed",
      error: "Extraction attempt was superseded before it completed",
      completed_at: Time.current,
      metadata: (attempt.metadata || {}).merge("superseded" => true)
    )
  end

  def sanitized_attempt_metadata(metadata)
    payload = metadata.is_a?(Hash) ? metadata : {}
    {
      "usage" => sanitized_usage(metadata_value(payload, :usage, "usage")),
      "finish_reason" => sanitized_metadata_string(metadata_value(payload, :finish_reason, "finish_reason")),
      "provider" => sanitized_provider(metadata_value(payload, :provider, "provider")),
      "status_code" => sanitized_status_code(metadata_value(payload, :status_code, "status_code"))
    }.compact_blank
  end

  def sanitized_usage(usage)
    return unless usage.is_a?(Hash)

    usage.each_with_object({}) do |(key, value), sanitized|
      key = key.to_s
      next unless key.in?(ATTEMPT_USAGE_KEYS)
      next unless value.is_a?(Numeric)

      sanitized[key] = value
    end.presence
  end

  def sanitized_provider(provider)
    value = provider.is_a?(Hash) ? provider["name"] || provider[:name] || provider["id"] || provider[:id] : provider
    sanitized_metadata_string(value)
  end

  def sanitized_status_code(status_code)
    Integer(status_code)
  rescue ArgumentError, TypeError
    nil
  end

  def sanitized_metadata_string(value)
    value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish.truncate(ATTEMPT_METADATA_STRING_LENGTH, omission: "…").presence
  end

  def metadata_value(payload, *keys)
    keys.find { |key| payload.key?(key) }.then { |key| key ? payload[key] : nil }
  end
end
