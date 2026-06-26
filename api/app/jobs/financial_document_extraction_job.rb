# frozen_string_literal: true

class FinancialDocumentExtractionJob < ApplicationJob
  queue_as :default

  def perform(financial_document_import_id)
    document_import = FinancialDocumentImport.find_by(id: financial_document_import_id)
    return unless document_import
    return if document_import.source_deleted_at.present?

    extractor = FinancialDocuments::Extractor.new
    attempt = nil

    document_import.with_lock do
      return if document_import.source_deleted_at.present?

      document_import.update!(status: "processing", extraction_error: nil)
      attempt = document_import.attempts.create!(
        provider: "openrouter",
        model: extractor.model,
        status: "processing",
        prompt_version: FinancialDocuments::Extractor::PROMPT_VERSION,
        schema_version: FinancialDocuments::Extractor::SCHEMA_VERSION,
        started_at: Time.current
      )
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

      document_import.items.where(applied_at: nil).delete_all
      Array(data[:items]).each do |item_attributes|
        document_import.items.create!(item_attributes)
      end

      metadata = (document_import.metadata || {}).merge(
        "confidence" => data[:confidence],
        "warnings" => data[:warnings],
        "extraction_model" => attempt.model,
        "last_extracted_at" => Time.current.iso8601
      ).compact

      document_import.update!(
        document_kind: data[:document_kind] || document_import.document_kind,
        status: "needs_review",
        document_date: data[:document_date],
        period_start_on: data[:period_start_on],
        period_end_on: data[:period_end_on],
        extracted_summary: data[:summary],
        extraction_error: nil,
        processed_at: Time.current,
        metadata: metadata
      )

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
        processed_at: Time.current,
        metadata: (document_import.metadata || {}).merge("last_extraction_failed_at" => Time.current.iso8601)
      )
      attempt&.update!(
        status: "failed",
        error: error.to_s.truncate(1000, omission: "…"),
        completed_at: Time.current,
        metadata: sanitized_attempt_metadata(metadata)
      )
    end
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
    payload.slice(:usage, :finish_reason, :provider, "usage", "finish_reason", "provider", :status_code, "status_code")
  end
end
