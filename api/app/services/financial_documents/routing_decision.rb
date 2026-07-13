# frozen_string_literal: true

module FinancialDocuments
  class RoutingDecision
    Result = Data.define(
      :declared_kind,
      :detected_kind,
      :context_kind,
      :resolved_kind,
      :source,
      :conflict,
      :conflict_reason,
      :requires_confirmation,
      :destination
    )

    DESTINATIONS = {
      "receipt" => "transaction_review",
      "statement" => "transaction_review",
      "pay_stub" => "household_setup_review",
      "spreadsheet" => "household_setup_review",
      "other" => "private_document_review"
    }.freeze

    CONTEXT_PATTERNS = {
      "pay_stub" => /\b(?:pay\s*stub|paycheck|earnings statement|wage statement)\b/i,
      "statement" => /\b(?:(?:bank|checking|savings|credit card|card|account)\s+statement|statement\s+(?:page|pages|screenshot|screenshots|pdf|file)|transaction\s+history)\b/i,
      "receipt" => /\b(?:receipt|purchase slip|store slip)\b/i,
      "spreadsheet" => /\b(?:(?:my|our|household|monthly|annual|family)\s+budget|budget\s+(?:file|spreadsheet|sheet|plan|template|worksheet)|expense\s+stack|income\s+(?:and|&)\s+expenses)\b/i
    }.freeze

    def initialize(document_import, detected_kind:)
      @document_import = document_import
      @detected_kind = valid_kind(detected_kind)
    end

    def call
      declared_kind = valid_kind(document_import.metadata.to_h["declared_document_kind"]) || valid_kind(document_import.document_kind) || "other"
      context_kind = kind_from_context(document_import.metadata.to_h["upload_context"])
      explicit_selection = document_import.metadata.to_h["document_kind_explicit"] == true || document_import.metadata.to_h["upload_origin"] == "profile"
      participant_kind = context_kind || (declared_kind if explicit_selection)
      participant_signal_conflict = context_kind.present? && explicit_selection && context_kind != declared_kind
      detection_conflict = participant_kind.present? && detected_kind.present? && detected_kind != "other" && participant_kind != detected_kind
      conflict = participant_signal_conflict || detection_conflict
      conflict_reason = participant_signal_conflict ? "participant_signals" : ("mia_detection" if detection_conflict)

      resolved_kind, source = if participant_kind.present?
        [ participant_kind, context_kind.present? ? "participant_context" : "participant_selection" ]
      elsif detected_kind.present? && detected_kind != "other"
        [ detected_kind, "mia_detection" ]
      else
        [ declared_kind, "file_default" ]
      end

      Result.new(
        declared_kind: declared_kind,
        detected_kind: detected_kind,
        context_kind: context_kind,
        resolved_kind: resolved_kind,
        source: source,
        conflict: conflict,
        conflict_reason: conflict_reason,
        requires_confirmation: conflict,
        destination: DESTINATIONS.fetch(resolved_kind, "private_document_review")
      )
    end

    private

    attr_reader :document_import, :detected_kind

    def valid_kind(value)
      kind = value.to_s
      kind if kind.in?(FinancialDocumentImport::DOCUMENT_KINDS)
    end

    def kind_from_context(value)
      context = value.to_s.unicode_normalize(:nfkc).squish.first(500)
      CONTEXT_PATTERNS.find { |_kind, pattern| context.match?(pattern) }&.first
    end
  end
end
