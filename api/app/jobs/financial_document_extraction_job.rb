# frozen_string_literal: true

class FinancialDocumentExtractionJob < ApplicationJob
  queue_as :default

  ATTEMPT_METADATA_STRING_LENGTH = 120
  ATTEMPT_USAGE_KEYS = %w[prompt_tokens completion_tokens total_tokens].freeze
  EXTRACTION_SUCCESS_METADATA_KEYS = %w[confidence warnings extraction_model extraction_mode extraction_page_count extraction_batch_count last_extracted_at transaction_draft_count transaction_match_count no_reviewable_transactions routing_detected_kind routing_resolved_kind routing_source routing_conflict routing_conflict_reason routing_requires_confirmation routing_destination source_accounting_revision_id source_accounting_contract_version source_accounting_review_pending source_reconciliation extraction_parser_version extraction_template extraction_financial_row_count extraction_informational_row_count extraction_printed_arithmetic_verified].freeze
  STALE_PROCESSING_AFTER = 15.minutes

  def perform(financial_document_import_id, dispatch_id = nil, generation = nil)
    @dispatch = nil
    @dispatch_generation = nil
    document_import = FinancialDocumentImport.find_by(id: financial_document_import_id)
    return unless document_import
    extractor = nil
    attempt = nil

    document_import.with_lock do
      @dispatch = if dispatch_id
        FinancialDocumentExtractionDispatch.find_by(id: dispatch_id, financial_document_import_id: document_import.id)
      elsif document_import.status.in?(%w[uploaded processing])
        FinancialDocumentExtractionDispatch.request!(document_import)
      end
      return unless @dispatch
      @dispatch.lock!
      return if generation && @dispatch.generation != generation
      return if @dispatch.status.in?(%w[completed cancelled])
      unless document_import.source_available?
        @dispatch.cancel!("source_unavailable")
        return
      end
      unless @dispatch.source_fingerprint == FinancialDocumentExtractionDispatch.fingerprint(document_import)
        @dispatch.cancel!("source_changed")
        return
      end
      @dispatch_generation = @dispatch.generation
      unless extraction_startable?(document_import)
        schedule_stale_processing_recheck!(document_import) if document_import.status == "processing"
        return
      end

      extractor = FinancialDocuments::Extractor.new
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
      @dispatch.update!(status: "processing", lease_token: nil,
        lease_expires_at: STALE_PROCESSING_AFTER.from_now, next_attempt_at: STALE_PROCESSING_AFTER.from_now)
    end

    document_import.reload
    unless document_import.source_available?
      document_import.with_lock do
        mark_attempt_superseded!(attempt)
        @dispatch.cancel!("source_unavailable") if @dispatch.reload.generation == @dispatch_generation
      end
      return
    end
    result = extractor.call(document_import) { renew_processing_lease!(document_import, attempt) }
    if result.success?
      persist_success!(document_import, attempt, result)
    else
      persist_failure!(document_import, attempt, result.error, result.metadata)
    end
  rescue StandardError => e
    Rails.logger.error("[FinancialDocumentExtractionJob] import #{financial_document_import_id} failed_class=#{e.class}")
    persist_failure_safely(document_import, attempt, "Document extraction could not finish. Try reprocessing the document.") if defined?(document_import) && document_import && attempt
  end

  private

  def persist_success!(document_import, attempt, result)
    data = result.data
    document_import.with_lock do
      unless authoritative_attempt?(document_import, attempt)
        reject_result!(document_import, attempt)
        return
      end

      native = result.metadata[:extraction_mode] == "native_statement"
      if native
        attempt.update!(provider: "native_pdf", model: FinancialDocuments::NativeStatementParser::VERSION,
          prompt_version: FinancialDocuments::NativeStatementParser::VERSION)
      end
      routing = FinancialDocuments::RoutingDecision.new(document_import, detected_kind: data[:document_kind]).call
      accounting = data[:source_accounting]
      accounting ||= FinancialDocuments::AccountingContract.legacy(Array(data[:transaction_drafts]), coverage: { expected_page_count: result.metadata[:page_count] })
      source_result = FinancialDocuments::SourceAccountingPersister.new(document_import, attempt: attempt, accounting: accounting,
        structured_spreadsheet: result.metadata[:extraction_mode] == "structured_spreadsheet").call
      typed_accounting = accounting[:contract_version] == FinancialDocuments::AccountingContract::VERSION
      document_import.document_kind = routing.resolved_kind
      document_import.items.where(applied_at: nil).delete_all
      Array(data[:items]).each do |item_attributes|
        document_import.items.create!(item_attributes.merge(selected: false))
      end
      extracted_transaction_drafts = typed_accounting ? source_result.fetch(:transaction_drafts) : Array(data[:transaction_drafts])
      draft_result = HouseholdFinance::DocumentTransactionDraftPersister.new(document_import, extracted_transaction_drafts).call
      if !typed_accounting && extracted_transaction_drafts.any? && draft_result.fetch(:created_count).zero? &&
          !document_import.items.where(applied_at: nil, ignored: false).exists?
        reason = draft_result.fetch(:warnings).first.presence || "No transaction could be safely validated."
        raise ArgumentError, "Mia found spending transactions, but none could be saved for review. #{reason}"
      end

      no_reviewable_transactions = Array(data[:items]).empty? && extracted_transaction_drafts.empty? &&
        !document_import.items.exists? && !document_import.transaction_drafts.exists? &&
        (!typed_accounting || source_result.fetch(:events).empty?)
      warnings = Array(data[:warnings]) + Array(draft_result.fetch(:warnings))
      if routing.conflict
        warning = if routing.conflict_reason == "participant_signals"
          "Your message described this as #{routing.resolved_kind.humanize.downcase}, while the selected type was #{routing.declared_kind.humanize.downcase}. Mia used your message and left every extracted value pending for you to verify."
        else
          "You described this as #{routing.resolved_kind.humanize.downcase}, while Mia detected #{routing.detected_kind.humanize.downcase}. Mia kept your description and left every extracted value pending for you to verify."
        end
        warnings.unshift(warning)
      end

      metadata = (document_import.metadata || {}).except(*EXTRACTION_SUCCESS_METADATA_KEYS).merge(
        "source_accounting_revision_id" => source_result.fetch(:revision).id,
        "source_accounting_contract_version" => accounting[:contract_version],
        "source_accounting_review_pending" => typed_accounting,
        "source_reconciliation" => source_result.fetch(:reconciliation),
        "confidence" => data[:confidence],
        "warnings" => warnings.first(FinancialDocuments::Extractor::MAX_WARNINGS),
        "extraction_model" => native ? nil : attempt.model,
        "extraction_parser_version" => native ? FinancialDocuments::NativeStatementParser::VERSION : nil,
        "extraction_template" => native ? sanitized_metadata_string(result.metadata[:template]) : nil,
        "extraction_financial_row_count" => native ? result.metadata[:financial_row_count] : nil,
        "extraction_informational_row_count" => native ? result.metadata[:informational_row_count] : nil,
        "extraction_printed_arithmetic_verified" => native ? result.metadata[:printed_arithmetic_verified] == true : nil,
        "extraction_mode" => result.metadata[:extraction_mode],
        "extraction_page_count" => result.metadata[:page_count],
        "extraction_batch_count" => result.metadata[:batch_count],
        "last_extracted_at" => Time.current.iso8601,
        "transaction_draft_count" => draft_result.fetch(:created_count),
        "transaction_match_count" => draft_result.fetch(:match_count),
        "no_reviewable_transactions" => no_reviewable_transactions.presence,
        "routing_detected_kind" => routing.detected_kind,
        "routing_resolved_kind" => routing.resolved_kind,
        "routing_source" => routing.source,
        "routing_conflict" => routing.conflict,
        "routing_conflict_reason" => routing.conflict_reason,
        "routing_requires_confirmation" => routing.requires_confirmation,
        "routing_destination" => routing.destination
      ).compact

      document_import.update!(
        document_kind: routing.resolved_kind,
        status: "needs_review",
        document_date: data[:document_date],
        period_start_on: data[:period_start_on],
        period_end_on: data[:period_end_on],
        extracted_summary: typed_accounting ? "Retained #{source_result.fetch(:events).length} source rows and proposed #{draft_result.fetch(:created_count)} expenses. Source coverage and classifications still require review." : data[:summary],
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
      finish_dispatch!("extracted")
    end
  rescue StandardError => e
    persist_failure!(document_import, attempt, e.message, result&.metadata || {})
  end

  def persist_failure!(document_import, attempt, error, metadata = {})
    document_import.with_lock do
      unless authoritative_attempt?(document_import, attempt)
        reject_result!(document_import, attempt)
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
      finish_dispatch!("extraction_failed")
    end
  end

  def extraction_startable?(document_import)
    document_import.status == "uploaded" || stale_processing?(document_import)
  end

  def stale_processing?(document_import)
    document_import.status == "processing" && document_import.updated_at.present? && document_import.updated_at <= STALE_PROCESSING_AFTER.ago
  end

  def schedule_stale_processing_recheck!(document_import)
    retry_at = document_import.updated_at + STALE_PROCESSING_AFTER
    @dispatch.update!(status: "processing", lease_token: nil,
      lease_expires_at: retry_at, next_attempt_at: retry_at)
  end

  def renew_processing_lease!(document_import, attempt)
    document_import.with_lock do
      return false unless authoritative_attempt?(document_import, attempt)

      document_import.touch
      @dispatch.update!(lease_expires_at: STALE_PROCESSING_AFTER.from_now,
        next_attempt_at: STALE_PROCESSING_AFTER.from_now)
      true
    end
  end

  def finish_dispatch!(code)
    @dispatch.update!(status: "completed", lease_token: nil, lease_expires_at: nil, error_code: code)
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
    Rails.logger.warn("[FinancialDocumentExtractionJob] could not persist failure for import #{document_import&.id}: #{failure_error.class}")
  end

  def authoritative_attempt?(document_import, attempt)
    return false unless attempt

    attempt.reload
    return false unless attempt.status == "processing"
    return false unless document_import.status == "processing"
    return false unless document_import.source_available?
    return false unless @dispatch
    @dispatch.reload
    return false unless @dispatch.status == "processing" && @dispatch.generation == @dispatch_generation
    return false unless @dispatch.source_fingerprint == FinancialDocumentExtractionDispatch.fingerprint(document_import)

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

  def reject_result!(document_import, attempt)
    mark_attempt_superseded!(attempt)
    return unless @dispatch && @dispatch.reload.generation == @dispatch_generation

    if !document_import.source_available?
      @dispatch.cancel!("source_unavailable")
    elsif @dispatch.source_fingerprint != FinancialDocumentExtractionDispatch.fingerprint(document_import)
      @dispatch.cancel!("source_changed")
    end
  end

  def sanitized_attempt_metadata(metadata)
    payload = metadata.is_a?(Hash) ? metadata : {}
    {
      "usage" => sanitized_usage(metadata_value(payload, :usage, "usage")),
      "finish_reason" => sanitized_metadata_string(metadata_value(payload, :finish_reason, "finish_reason")),
      "provider" => sanitized_provider(metadata_value(payload, :provider, "provider")),
      "status_code" => sanitized_status_code(metadata_value(payload, :status_code, "status_code")),
      "extraction_mode" => sanitized_metadata_string(metadata_value(payload, :extraction_mode, "extraction_mode")),
      "parser_version" => sanitized_metadata_string(metadata_value(payload, :parser_version, "parser_version")),
      "template" => sanitized_metadata_string(metadata_value(payload, :template, "template")),
      "printed_arithmetic_verified" => metadata_value(payload, :printed_arithmetic_verified, "printed_arithmetic_verified") == true ? true : nil
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
