# frozen_string_literal: true

module HouseholdFinance
  class AttachedDocumentQuestionAnswerer
    MAX_IMPORTS = 5
    MAX_TRANSACTION_ROWS = 2_500
    MAX_SETUP_ROWS = 300
    MAX_LISTED_ROWS = 8
    GENERIC_REVIEW_PATTERN = /\A(?:please\s+)?(?:review|read|check|process|summarize)\b/i
    SUBSTANTIVE_QUESTION_PATTERN = /\b(?:total|sum|how much|largest|biggest|highest|which|what|merchant|where|category|when|date|period|over\s+\$|under\s+\$)\b/i
    SETUP_REQUEST_PATTERN = /\A(?:(?:can|could|would)\s+you\s+)?(?:use|set up|import).{0,100}\b(?:budget|profile|household|income)\b/i

    def self.generic_review_request?(message)
      normalized = message.to_s.squish
      (normalized.match?(GENERIC_REVIEW_PATTERN) && !normalized.match?(SUBSTANTIVE_QUESTION_PATTERN)) || normalized.match?(SETUP_REQUEST_PATTERN)
    end

    def initialize(household, message:, document_imports:)
      @household = household
      @message = message.to_s.squish
      @document_imports = Array(document_imports).first(MAX_IMPORTS)
    end

    def call
      return unless document_imports.any?
      return unless document_imports.all? { |document_import| document_import.household_id == household.id }

      rows = transaction_rows
      setup = setup_rows
      return no_evidence_answer if rows.empty? && setup.empty?

      parts = direct_answer_parts(rows, setup)
      parts << overview(rows, setup) if parts.empty?
      parts << failed_import_notice
      parts << review_boundary(rows, setup)
      parts.compact.join(" ")
    end

    private

    attr_reader :household, :message, :document_imports

    def transaction_rows
      @transaction_rows ||= TransactionDraft
        .where(financial_document_import_id: evidence_imports.map(&:id), household_id: household.id)
        .includes(:budget_category, :transaction_draft_splits)
        .order(:occurred_on, :id)
        .limit(MAX_TRANSACTION_ROWS)
        .map do |draft|
          {
            merchant: draft.merchant,
            amount_cents: draft.total_amount_cents,
            occurred_on: draft.occurred_on,
            category: draft.budget_category&.name || draft.transaction_draft_splits.first&.category_name || "Uncategorized",
            status: draft.status
          }
        end
    end

    def setup_rows
      @setup_rows ||= FinancialDocumentImportItem
        .where(financial_document_import_id: evidence_imports.map(&:id), ignored: false)
        .order(:id)
        .limit(MAX_SETUP_ROWS)
        .map do |item|
          {
            target_type: item.target_type,
            label: item.label,
            amount_cents: item.amount_cents,
            balance_cents: item.balance_cents,
            payment_cents: item.payment_cents,
            cadence: item.cadence,
            interest_rate_percent: item.interest_rate_percent,
            state: item.applied? ? "applied" : "pending review"
          }
        end
    end

    def evidence_imports
      @evidence_imports ||= document_imports.reject { |document_import| document_import.status.in?(%w[uploaded processing failed]) }
    end

    def direct_answer_parts(rows, setup)
      parts = []
      if transaction_question? && explicit_transaction_scope?(rows) && scoped_transaction_rows(rows).empty?
        parts << "I found no attached transaction row matching the named merchant or category."
        return parts
      end
      parts << transaction_total_answer(rows) if transaction_total_question? && rows.any?
      parts << largest_transaction_answer(rows) if largest_question? && rows.any?
      parts << transaction_list_answer(rows) if transaction_list_question? && rows.any?
      parts << category_answer(rows) if category_question? && rows.any?
      parts << date_answer(rows) if date_question? && rows.any?
      parts << setup_answer(setup) if setup_question? && setup.any?
      parts.compact.uniq
    end

    def transaction_total_answer(rows)
      scoped = scoped_transaction_rows(rows)
      matching = threshold_filtered(scoped)
      qualifier = matching.length == rows.length ? "" : " matching that merchant, category, or amount filter"
      "The attached evidence has #{matching.length} transaction row#{'s' unless matching.one?}#{qualifier} totaling #{money(matching.sum { |row| row.fetch(:amount_cents) })}."
    end

    def largest_transaction_answer(rows)
      row = threshold_filtered(scoped_transaction_rows(rows)).max_by { |candidate| candidate.fetch(:amount_cents) }
      return "I found no attached transaction row matching those filters." unless row

      "The largest attached transaction is #{row.fetch(:merchant)} for #{money(row.fetch(:amount_cents))} on #{formatted_date(row.fetch(:occurred_on))}, categorized as #{row.fetch(:category)}."
    end

    def transaction_list_answer(rows)
      matching = threshold_filtered(scoped_transaction_rows(rows))
      return "I found no attached transaction row matching those filters." if matching.empty?

      listed = matching.first(MAX_LISTED_ROWS).map do |row|
        "#{row.fetch(:merchant)} — #{money(row.fetch(:amount_cents))} on #{formatted_date(row.fetch(:occurred_on))} (#{row.fetch(:category)}, #{status_label(row.fetch(:status))})"
      end
      suffix = matching.length > listed.length ? "; plus #{matching.length - listed.length} more attached row#{'s' unless matching.length - listed.length == 1}" : ""
      "Attached transactions: #{listed.join('; ')}#{suffix}."
    end

    def category_answer(rows)
      totals = threshold_filtered(scoped_transaction_rows(rows)).group_by { |row| row.fetch(:category) }.map do |category, category_rows|
        [ category, category_rows.sum { |row| row.fetch(:amount_cents) } ]
      end.sort_by { |(_category, amount)| -amount }
      return if totals.empty?

      listed = totals.first(MAX_LISTED_ROWS).map { |category, amount| "#{category}: #{money(amount)}" }
      "Attached transaction totals by category are #{listed.to_sentence}."
    end

    def date_answer(rows)
      dates = threshold_filtered(scoped_transaction_rows(rows)).filter_map { |row| row.fetch(:occurred_on) }
      return if dates.empty?

      range = dates.min == dates.max ? formatted_date(dates.min) : "#{formatted_date(dates.min)} through #{formatted_date(dates.max)}"
      "The attached transaction dates cover #{range}."
    end

    def setup_answer(setup)
      relevant = setup.select { |row| setup_type_matches_question?(row.fetch(:target_type)) }
      relevant = setup if relevant.empty?
      listed = relevant.first(MAX_LISTED_ROWS).map { |row| setup_row_label(row) }
      suffix = relevant.length > listed.length ? "; plus #{relevant.length - listed.length} more value#{'s' unless relevant.length - listed.length == 1}" : ""
      "The attached setup evidence shows #{listed.join('; ')}#{suffix}."
    end

    def overview(rows, setup)
      parts = []
      if rows.any?
        dates = rows.filter_map { |row| row.fetch(:occurred_on) }
        date_text = dates.any? ? " from #{formatted_date(dates.min)} through #{formatted_date(dates.max)}" : ""
        parts << "#{rows.length} transaction row#{'s' unless rows.one?} totaling #{money(rows.sum { |row| row.fetch(:amount_cents) })}#{date_text}"
      end
      parts << "#{setup.length} budget/profile value#{'s' unless setup.one?}" if setup.any?
      "From the explicitly attached import#{'s' if document_imports.many?}, I can verify #{parts.to_sentence}."
    end

    def review_boundary(rows, setup)
      pending_transactions = rows.count { |row| row.fetch(:status) == "pending" }
      pending_setup = setup.count { |row| row.fetch(:state) == "pending review" }
      if pending_transactions.positive? || pending_setup.positive?
        "#{pending_transactions + pending_setup} extracted value#{'s' unless pending_transactions + pending_setup == 1} remain pending review; nothing from this chat turn was applied and pending transactions are not actuals."
      else
        "These are saved import results; this chat turn did not write or apply any household value."
      end
    end

    def failed_import_notice
      count = document_imports.count(&:failed?)
      return if count.zero?

      "#{count} attached upload#{'s' unless count == 1} failed extraction and contributed no evidence to this answer."
    end

    def no_evidence_answer
      failed = document_imports.count(&:failed?)
      if failed.positive?
        "I could not answer that question from the attached upload#{'s' if document_imports.many?}: #{failed} failed extraction and produced no verified rows. The upload is saved, and no household numbers changed."
      else
        "I read the attached upload#{'s' if document_imports.many?}, but there are no structured transaction or setup values that can answer that question without guessing. No household numbers changed."
      end
    end

    def transaction_total_question?
      message.match?(/\b(?:total|sum|how much|amount|spend|spent|paid|charges?)\b/i) || message.match?(/\b(?:over|above|more than|greater than|under|below|less than)\s+\$/i)
    end

    def transaction_question?
      transaction_total_question? || largest_question? || transaction_list_question? || category_question? || date_question?
    end

    def largest_question?
      message.match?(/\b(?:largest|biggest|highest|most expensive)\b/i)
    end

    def transaction_list_question?
      message.match?(/\b(?:which|what|list|show|merchant|where|transactions?|purchases?|charges?)\b/i) && !setup_question?
    end

    def category_question?
      message.match?(/\b(?:category|categories|categorized|type of spending)\b/i)
    end

    def date_question?
      message.match?(/\b(?:when|date|dates|period|range|month)\b/i)
    end

    def setup_question?
      message.match?(/\b(?:income|paycheck|pay stub|salary|expense|budget|profile|account|balance|debt|payment|goal|setup|set up)\b/i)
    end

    def setup_type_matches_question?(type)
      patterns = {
        "income_source" => /\b(?:income|paycheck|pay stub|salary)\b/i,
        "expense_item" => /\b(?:expense|budget|spend)\b/i,
        "account" => /\b(?:account|balance|asset)\b/i,
        "debt" => /\b(?:debt|loan|card|payment|balance)\b/i,
        "goal" => /\bgoal\b/i,
        "profile_note" => /\b(?:profile|note)\b/i
      }
      message.match?(patterns.fetch(type, /\A\b\B/))
    end

    def threshold_filtered(rows)
      amount = message[/\$\s*([\d,]+(?:\.\d{1,2})?)/, 1]
      return rows unless amount

      cents = Money.cents(amount.delete(","))
      if message.match?(/\b(?:over|above|more than|greater than)\b/i)
        rows.select { |row| row.fetch(:amount_cents) > cents }
      elsif message.match?(/\b(?:under|below|less than)\b/i)
        rows.select { |row| row.fetch(:amount_cents) < cents }
      else
        rows
      end
    end

    def scoped_transaction_rows(rows)
      matches = matching_transaction_entities(rows)
      return rows unless matches.any? || unmatched_transaction_scope_requested?

      rows.select do |row|
        matches.any? do |match|
          normalized_entity(row.fetch(match.fetch(:field))) == match.fetch(:value)
        end
      end
    end

    def explicit_transaction_scope?(rows)
      matching_transaction_entities(rows).any? || unmatched_transaction_scope_requested?
    end

    def matching_transaction_entities(rows)
      @matching_transaction_entities ||= begin
        normalized = " #{normalized_entity(message)} "
        rows.flat_map do |row|
          %i[merchant category].filter_map do |field|
            value = normalized_entity(row.fetch(field))
            next if value.blank? || !normalized.include?(" #{value} ")

            { field: field, value: value }
          end
        end.uniq
      end
    end

    def unmatched_transaction_scope_requested?
      @unmatched_transaction_scope_requested ||= begin
        candidate = message.match(/\b(?:at|from)\s+([^?.,;]{2,60})/i)&.[](1) ||
          message.match(/\bsp(?:end|ent|ending)\s+on\s+([^?.,;]{2,60})/i)&.[](1) ||
          message.match(/\b(?:in|under)\s+(?:the\s+)?([^?.,;]{2,60}?)\s+categor(?:y|ies)\b/i)&.[](1) ||
          message.match(/\bcategory\s+(?:named|called)\s+["']?([^?.,;"']{2,60})/i)&.[](1)
        candidate.present? && !generic_attachment_reference?(candidate)
      end
    end

    def generic_attachment_reference?(candidate)
      normalized_entity(candidate).match?(/\A(?:this|these|the|my|attached)?\s*(?:upload|uploads|file|files|document|documents|receipt|receipts|statement|statements|attachment|attachments)\z/)
    end

    def normalized_entity(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def setup_row_label(row)
      values = []
      values << money(row[:amount_cents]) if row[:amount_cents]
      values << "balance #{money(row[:balance_cents])}" if row[:balance_cents]
      values << "payment #{money(row[:payment_cents])}" if row[:payment_cents]
      values << "#{row[:interest_rate_percent]}% APR" if row[:interest_rate_percent]
      values << row[:cadence] if row[:cadence].present?
      "#{row.fetch(:label)}: #{values.join(', ')} (#{row.fetch(:state)})"
    end

    def status_label(status)
      status == "pending" ? "pending review" : status.to_s.humanize.downcase
    end

    def formatted_date(date)
      date&.strftime("%b %-d, %Y") || "date unavailable"
    end

    def money(cents)
      ActionController::Base.helpers.number_to_currency(cents.to_i / 100.0)
    end
  end
end
