# frozen_string_literal: true

module HouseholdFinance
  class AttachedDocumentFollowupResolver
    Result = Data.define(:prompt, :query_scope)

    FOLLOW_UP_REFERENCE = /\b(?:that|those|it|them|this|these|upload|uploads|attachment|attachments|receipt|receipts|statement|statements|file|files|document|documents)\b/i
    ELLIPTICAL_PREFIX = /\A\s*(?:and\s+)?(?:what|how)\s+about\b/i
    DATE_SHORTHAND = /\A\s*(?:and\s+)?(?:only\s+)?(?:today|yesterday|this month|last month|next month|(?:in|for|during|only)\s+#{AttachedDocumentQuestionAnswerer::MONTH_PATTERN}|#{AttachedDocumentQuestionAnswerer::MONTH_PATTERN}(?:\s+(?:19|20)\d{2})?\s+only)\b/i
    EVIDENCE_QUESTION = /\b(?:total|sum|largest|biggest|highest|merchant|transaction|purchase|charge|category|categorized|when|date|period|month|duplicate|fit|fits|within|covered|room|over\s+\$|under\s+\$)\b/i
    CLEARLY_UNRELATED_TOPIC = /\b(?:runway|safe to spend|readiness|red status|yellow status|green status|emergency fund|leave (?:my )?job|quit (?:my )?job|debt (?:strategy|payoff)|credit score|retirement)\b/i
    NEW_ADVICE_OR_ACTION = /\b(?:should|could i|can i|would it be better|set|change|update|increase|decrease|raise|lower|create|rename|archive|budget\s+(?:be|for))\b/i
    EXPLICIT_EVIDENCE_REFERENCE = /\b(?:upload|uploads|attachment|attachments|receipt|receipts|statement|statements|file|files|document|documents)\b/i

    def initialize(household, message:, document_imports:, prior_query_scope: nil)
      @household = household
      @message = message.to_s.squish
      @document_imports = Array(document_imports).first(DocumentEvidenceContinuity::MAX_IMPORTS)
      @prior_query_scope = sanitized_scope(prior_query_scope)
    end

    def self.evidence_style_reference?(message)
      normalized = message.to_s.squish
      return false if normalized.blank? || normalized.match?(CLEARLY_UNRELATED_TOPIC)
      return false if normalized.match?(NEW_ADVICE_OR_ACTION) && !normalized.match?(/\b(?:fit|fits|within|covered by|room in)\b.{0,60}\b(?:plan|budget)\b|\b(?:plan|budget)\b.{0,60}\b(?:fit|fits|within|cover|room)\b/i)

      (normalized.match?(FOLLOW_UP_REFERENCE) && normalized.match?(EVIDENCE_QUESTION)) || normalized.match?(DATE_SHORTHAND)
    end

    def self.elliptical_scope_reference?(message, query_scope)
      normalized = message.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^a-z0-9]+/, " ").squish
      return false unless normalized.match?(ELLIPTICAL_PREFIX)
      return false if normalized.match?(CLEARLY_UNRELATED_TOPIC) || normalized.match?(NEW_ADVICE_OR_ACTION)

      entities = Array(query_scope.to_h.deep_symbolize_keys[:entities]).first(DocumentEvidenceContinuity::MAX_SCOPE_ENTITIES)
      entities.any? do |entity|
        value = entity.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^a-z0-9]+/, " ").squish
        value.present? && " #{normalized} ".include?(" #{value} ")
      end
    end

    def call
      return if message.blank? || document_imports.empty?
      return if message.match?(CLEARLY_UNRELATED_TOPIC)
      return if message.match?(NEW_ADVICE_OR_ACTION) && !plan_fit_question?
      return unless self.class.evidence_style_reference?(message) || elliptical_entity_follow_up?

      if referenced_evidence_question?
        scope = explicit_evidence_reference? ? current_scope : merged_scope
        prompt = plan_fit_question? ? plan_fit_prompt(scope) : scoped_prompt(message, scope)
        return Result.new(prompt: prompt, query_scope: scope)
      end
      if elliptical_entity_follow_up?
        scope = merged_scope(replace_entities: true)
        return Result.new(prompt: total_prompt(scope), query_scope: scope)
      end
      if date_shorthand_follow_up?
        scope = merged_scope
        return Result.new(prompt: total_prompt(scope), query_scope: scope)
      end

      nil
    end

    def query_scope
      current_scope
    end

    private

    attr_reader :household, :message, :document_imports, :prior_query_scope

    def referenced_evidence_question?
      message.match?(FOLLOW_UP_REFERENCE) && message.match?(EVIDENCE_QUESTION)
    end

    def elliptical_entity_follow_up?
      message.match?(ELLIPTICAL_PREFIX) && current_scope.fetch(:entities, []).any?
    end

    def date_shorthand_follow_up?
      message.match?(DATE_SHORTHAND)
    end

    def plan_fit_question?
      message.match?(/\b(?:fit|fits|within|covered by|room in)\b.{0,60}\b(?:plan|budget)\b|\b(?:plan|budget)\b.{0,60}\b(?:fit|fits|within|cover|room)\b/i)
    end

    def explicit_evidence_reference?
      message.match?(EXPLICIT_EVIDENCE_REFERENCE)
    end

    def merged_scope(replace_entities: false)
      current = current_scope
      prior = prior_query_scope
      entities = if replace_entities && current[:entities].present?
        current[:entities]
      else
        current[:entities].presence || prior[:entities]
      end
      {
        entities: entities,
        date_filter: current[:date_filter].presence || prior[:date_filter]
      }.compact
    end

    def total_prompt(scope)
      parts = [ "What is the total" ]
      parts << "for #{scope.fetch(:entities).to_sentence}" if scope[:entities].present?
      parts << scope[:date_filter] if scope[:date_filter].present?
      "#{parts.join(' ')}?"
    end

    def plan_fit_prompt(scope)
      subject = scope[:entities].present? ? scope.fetch(:entities).to_sentence : "that"
      date = scope[:date_filter].present? ? " #{scope[:date_filter]}" : ""
      "Does #{subject}#{date} fit my plan?"
    end

    def scoped_prompt(original, scope)
      return original if current_scope.present? || scope.blank?

      filters = []
      filters << "for #{scope.fetch(:entities).to_sentence}" if scope[:entities].present?
      filters << scope[:date_filter] if scope[:date_filter].present?
      "#{original.sub(/[?.!]+\z/, '')} #{filters.join(' ')}?".squish
    end

    def current_scope
      @current_scope ||= {
        entities: mentioned_evidence_entities,
        date_filter: date_filter
      }.compact_blank
    end

    def mentioned_evidence_entities
      normalized_message = normalize(message)
      evidence_entities.select do |entity|
        variants = [ entity, entity.singularize, entity.pluralize ].uniq
        variants.any? { |variant| " #{normalized_message} ".include?(" #{variant} ") }
      end.first(DocumentEvidenceContinuity::MAX_SCOPE_ENTITIES)
    end

    def date_filter
      normalized = message.downcase
      return "today" if normalized.match?(/\btoday\b/)
      return "yesterday" if normalized.match?(/\byesterday\b/)
      return "this month" if normalized.match?(/\b(?:this|current) month\b/)
      return "last month" if normalized.match?(/\blast month\b/)
      return "next month" if normalized.match?(/\bnext month\b/)

      month = normalized.match(/\b(#{AttachedDocumentQuestionAnswerer::MONTH_PATTERN})(?:\s+((?:19|20)\d{2}))?\b/i)
      return unless month

      [ month[1], month[2] ].compact.join(" ").downcase
    end

    def evidence_entities
      @evidence_entities ||= begin
        ids = document_imports.map(&:id)
        merchants = TransactionDraft.current_picture.where(household_id: household.id, financial_document_import_id: ids).pluck(:merchant)
        categories = TransactionDraft
          .where(household_id: household.id, financial_document_import_id: ids)
          .left_joins(:budget_category, :transaction_draft_splits)
          .pluck("budget_categories.name", "transaction_draft_splits.category_name")
          .flatten
        setup_labels = FinancialDocumentImportItem.where(financial_document_import_id: ids).pluck(:label)
        [ *merchants, *categories, *setup_labels ].filter_map { |value| normalize(value).presence }.uniq
      end
    end

    def sanitized_scope(value)
      scope = value.to_h.deep_symbolize_keys
      {
        entities: Array(scope[:entities]).first(DocumentEvidenceContinuity::MAX_SCOPE_ENTITIES).filter_map { |entity| normalize(entity).presence },
        date_filter: normalize(scope[:date_filter]).presence
      }.compact_blank
    end

    def normalize(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^a-z0-9]+/, " ").squish
    end
  end
end
