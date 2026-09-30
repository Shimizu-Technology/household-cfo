# frozen_string_literal: true

module HouseholdFinance
  module DocumentEvidenceContinuity
    TOPIC_SCHEMA_VERSION = 4
    EVIDENCE_SCHEMA_VERSION = 1
    MAX_IMPORTS = 5
    MAX_SCOPE_ENTITIES = 4
    MAX_RECORD_ID = 9_223_372_036_854_775_807
    READY_STATUSES = %w[needs_review applied partially_applied].freeze

    module_function

    def sanitize_topic(value, household:, require_ready: false)
      topic = value.to_h.deep_stringify_keys
      return topic if topic["document_evidence"].blank?

      unless topic["schema_version"].to_i >= TOPIC_SCHEMA_VERSION
        return nil if topic["type"] == "document_evidence"

        return topic.except("document_evidence")
      end

      evidence = payload(topic["document_evidence"], household: household, require_ready: require_ready)
      return nil if evidence.blank? && topic["type"] == "document_evidence"

      sanitized = topic.except("document_evidence")
      return sanitized if evidence.blank?

      sanitized.merge(
        "schema_version" => [ topic["schema_version"].to_i, TOPIC_SCHEMA_VERSION ].max,
        "document_evidence" => evidence
      )
    end

    def payload(value, household:, require_ready: false)
      evidence = value.to_h.deep_stringify_keys
      return unless evidence["schema_version"].to_i == EVIDENCE_SCHEMA_VERSION

      raw_ids = Array(evidence["financial_document_import_ids"]).first(MAX_IMPORTS)
      ids = raw_ids.map { |value| bounded_id(value) }
      return if ids.empty? || ids.any?(&:nil?) || ids.uniq.length != ids.length

      imports = household.financial_document_imports.where(id: ids, source_deleted_at: nil).index_by(&:id)
      return unless imports.length == ids.length
      return if require_ready && ids.any? { |id| !imports.fetch(id).status.in?(READY_STATUSES) }

      result = {
        "schema_version" => EVIDENCE_SCHEMA_VERSION,
        "financial_document_import_ids" => ids,
        "import_count" => ids.length
      }
      scope = query_scope(evidence["query_scope"])
      result["query_scope"] = scope if scope
      result
    end

    def topic?(value)
      value.to_h.deep_stringify_keys["type"] == "document_evidence"
    end

    def without_evidence(context)
      context = context.to_h.deep_symbolize_keys
      open_topics = Array(context[:open_topics]).reject { |topic| topic.to_h.deep_symbolize_keys[:type] == "document_evidence" }
      active_topic = context[:active_topic]
      active_topic = nil if active_topic.to_h.deep_symbolize_keys[:type] == "document_evidence"
      context.merge(active_topic: active_topic, open_topics: open_topics)
    end

    def bounded_id(value)
      id = Integer(value, exception: false)
      id if id&.positive? && id <= MAX_RECORD_ID
    end
    private_class_method :bounded_id

    def query_scope(value)
      scope = value.to_h.deep_stringify_keys
      entities = Array(scope["entities"])
        .first(MAX_SCOPE_ENTITIES)
        .filter_map { |entity| normalized_scope_text(entity, max_length: 80) }
        .uniq
      date_filter = normalized_scope_text(scope["date_filter"], max_length: 40)
      result = {}
      result["entities"] = entities if entities.any?
      result["date_filter"] = date_filter if date_filter
      result.presence
    end
    private_class_method :query_scope

    def normalized_scope_text(value, max_length:)
      value.to_s
        .unicode_normalize(:nfkc)
        .downcase
        .gsub(/[^a-z0-9\s-]/, " ")
        .squish
        .truncate(max_length, omission: "")
        .presence
    end
    private_class_method :normalized_scope_text
  end
end
