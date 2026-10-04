# frozen_string_literal: true

require "digest"
require "json"

module FinancialDocuments
  class AccountingContract
    VERSION = "source_accounting_v1"
    LEGACY_VERSION = "legacy_expense_only_v1"
    MAX_EVENTS = 2_000
    CENT_LIMIT = 99_999_999_999
    EXTRACTION_LIMITATIONS = %w[legacy_expense_only_contract signed_account_movement_unknown conflicting_debit_credit amount_missing_or_invalid transaction_direction_unclear merchant_missing].freeze

    def self.normalize(payload, coverage: {})
      new(payload, coverage: coverage).call
    end

    def self.legacy(drafts, coverage: {})
      rows = Array(drafts).map.with_index do |draft, index|
        draft = draft.is_a?(Hash) ? draft.deep_symbolize_keys : {}
        { account_key: "legacy", row_kind: "unresolved", event_type: "unknown", signed_amount_cents: nil,
          posted_on: draft[:occurred_on] || draft[:date], locator: { extraction_index: index },
          merchant: draft[:merchant], raw_description: draft[:raw_description], evidence: draft[:evidence],
          limitations: [ "legacy_expense_only_contract", "signed_account_movement_unknown" ] }
      end
      normalize({ contract_version: LEGACY_VERSION, accounts: [ { account_key: "legacy", account_basis: "unknown" } ], events: rows }, coverage: coverage)
    end

    def initialize(payload, coverage: {})
      @payload = payload.to_h.deep_symbolize_keys
      @coverage = @payload.fetch(:coverage, {}).to_h.deep_symbolize_keys.merge(coverage.to_h.deep_symbolize_keys)
      @accounts = []
      @account_keys = {}
    end

    def call
      unless payload[:contract_version].to_s.in?([ VERSION, LEGACY_VERSION ])
        raise ArgumentError, "Unsupported source accounting contract; no partial rows were accepted."
      end
      raw_events = Array(payload[:events])
      raise ArgumentError, "Source accounting contains more than #{MAX_EVENTS} rows; split the document without truncating rows." if raw_events.length > MAX_EVENTS

      Array(payload[:accounts]).each { |account| normalize_account(account.is_a?(Hash) ? account.deep_symbolize_keys : {}) }
      events = raw_events.map.with_index { |row, position| normalize_event(row.is_a?(Hash) ? row.deep_symbolize_keys : { malformed_extraction_row: JSON.generate(row) }, position) }
      events.group_by { |event| [ event[:source_key], event[:locator] ] }.each_value do |rows|
        next unless rows.many? && rows.first[:locator][:row]

        rows.each do |row|
          row[:limitations] << "duplicate_source_locator"
          row[:row_kind] = "unresolved" unless row[:row_kind] == "informational"
          row[:expense_amount_cents] = nil
        end
      end
      {
        contract_version: payload[:contract_version].to_s == LEGACY_VERSION ? LEGACY_VERSION : VERSION,
        accounts: accounts,
        events: events,
        coverage: coverage.merge(reported_row_count: integer(payload[:reported_row_count]), represented_row_count: events.length)
      }
    end

    private

    attr_reader :payload, :coverage, :accounts, :account_keys

    def normalize_account(raw)
      original_key = raw[:account_key].to_s.presence || "unknown"
      key = Digest::SHA256.hexdigest(original_key)
      existing = account_keys[key]
      if existing
        if raw[:account_basis].present? && raw[:account_basis] != "unknown" && existing[:account_basis] != raw[:account_basis]
          existing[:limitations] << "conflicting_header_account_basis"
        end
        return existing
      end

      basis = raw[:account_basis].to_s.in?(FinancialSourceAccount::BASES) ? raw[:account_basis].to_s : "unknown"
      account = {
        source_key: key, account_basis: basis,
        period_start_on: date(raw[:period_start_on]), period_end_on: date(raw[:period_end_on]),
        opening_balance_cents: cents(raw[:opening_balance_cents]), closing_balance_cents: cents(raw[:closing_balance_cents]),
        printed_debit_cents: nonnegative_cents(raw[:printed_debit_cents]), printed_credit_cents: nonnegative_cents(raw[:printed_credit_cents]),
        printed_row_count: integer(raw[:printed_row_count]), limitations: limitation_codes(raw[:limitations]),
        evidence: { label: text(raw[:label], 120), masked_identifier: text(raw[:masked_identifier], 24), header_evidence: text(raw[:header_evidence], 1_000), source_fields: source_fields(raw, %i[period_start_on period_end_on opening_balance_cents closing_balance_cents printed_debit_cents printed_credit_cents printed_row_count]), extraction_limitations: Array(raw[:limitations]).map { |value| text(value, 120) }.compact_blank }.compact_blank
      }
      account[:limitations] << "account_basis_unknown" if basis == "unknown"
      accounts << account
      account_keys[key] = account
    end

    def normalize_event(raw, position)
      account = normalize_account({ account_key: raw[:account_key] })
      limitations = limitation_codes(raw[:limitations])
      kind = raw[:row_kind].to_s.in?(FinancialSourceEvent::KINDS) ? raw[:row_kind].to_s : "unresolved"
      limitations << "row_kind_missing_or_invalid" unless raw[:row_kind].to_s.in?(FinancialSourceEvent::KINDS)
      type = raw[:event_type].to_s.in?(FinancialSourceEvent::TYPES) ? raw[:event_type].to_s : "unknown"
      amount = cents(raw[:signed_amount_cents])
      posted_on = date(raw[:posted_on])
      authorized_on = date(raw[:authorized_on])
      raw_locator = raw[:locator].is_a?(Hash) ? raw[:locator].deep_symbolize_keys : {}
      locator = raw_locator.slice(:page, :sheet_index, :row, :extraction_index).transform_values { |value| integer(value) }.compact
      description = [ raw[:merchant], raw[:raw_description], raw[:evidence] ].compact.join(" ")
      # Non-posted principal and summary rows must not become purchases even if
      # an extractor mistakenly emits their embedded dollar amount as a debit.
      if description.match?(/returned\s+unpaid|not\s+paid\s+because|total\s+(?:fees?|charges?)\s+(?:for|this)\s+(?:the\s+)?(?:statement\s+)?period/i)
        kind = "informational"
      end
      if kind != "informational"
        limitations << "signed_amount_missing_or_invalid" if amount.nil? || amount.zero?
        limitations << "posted_date_missing_or_invalid" unless posted_on
        limitations << "event_classification_unknown" if type == "unknown"
        limitations << "merchant_missing" if type.in?(%w[purchase fee]) && raw[:merchant].to_s.blank?
        limitations << "posted_date_outside_statement_period" if posted_on && account[:period_start_on] && account[:period_end_on] && !posted_on.between?(account[:period_start_on], account[:period_end_on])
        limitations << "source_row_locator_missing" unless locator[:row].to_i.positive?
        if coverage[:expected_page_count]
          limitations << "source_page_missing_or_outside_batch" unless locator[:page].to_i.positive? && Array(coverage[:processed_pages]).include?(locator[:page])
        elsif coverage[:processed_sheets]
          limitations << "source_sheet_missing_or_invalid" unless Array(coverage[:processed_sheets]).include?(locator[:sheet_index])
        end
        column_amount = cents(raw[:amount_column_cents])
        limitations << "amount_column_disagrees" if raw.key?(:amount_column_cents) && (column_amount.nil? || amount.nil? || column_amount.abs != amount.abs)
        limitations << "expense_direction_conflict" if type.in?(%w[purchase fee]) && !amount.to_i.negative?
        limitations << "incoming_direction_conflict" if type.in?(%w[refund income]) && !amount.to_i.positive?
      end
      funding = Array(raw[:funding_components]).map do |part|
        part = part.is_a?(Hash) ? part.deep_symbolize_keys : {}
        { source_key: Digest::SHA256.hexdigest(part[:account_key].to_s), amount_cents: nonnegative_cents(part[:amount_cents]) }
      end
      displayed_amount = amount
      amount = nil if kind == "informational"
      expense_amount = amount.to_i.negative? && type.in?(%w[purchase fee interest]) ? amount.abs : nil
      if raw[:purchase_total_cents].present?
        total = nonnegative_cents(raw[:purchase_total_cents])
        local = funding.select { |part| part[:source_key] == account[:source_key] }.sum { |part| part[:amount_cents].to_i }
        if type == "purchase" && total.to_i.positive? && funding.all? { |part| part[:amount_cents].to_i.positive? } && funding.sum { |part| part[:amount_cents] } == total && amount.to_i.negative? && local == amount.abs
          expense_amount = total
        else
          limitations << "split_funding_does_not_reconcile"
        end
      end
      kind = "unresolved" if kind != "informational" && limitations.any?
      expense_amount = nil unless kind == "posted"
      {
        source_key: account[:source_key], position: position,
        row_identity: Digest::SHA256.hexdigest(JSON.generate([ account[:source_key], locator, position ])),
        row_kind: kind, event_type: type, signed_amount_cents: amount,
        expense_amount_cents: expense_amount, posted_on: posted_on, authorized_on: authorized_on,
        locator: locator, funding_components: funding, limitations: limitations.uniq,
        evidence: { merchant: text(raw[:merchant], 120), raw_description: text(raw[:raw_description], 1_000), evidence: text(raw[:evidence], 1_000), source_amount_text: text(raw[:source_amount_text], 80), source_fields: source_fields(raw, %i[posted_on authorized_on source_posted_on source_authorized_on source_debit source_credit source_direction signed_amount_cents amount_column_cents row_kind event_type]), malformed_extraction_row: text(raw[:malformed_extraction_row], 1_000), extraction_limitations: Array(raw[:limitations]).map { |value| text(value, 120) }.compact_blank, displayed_amount_cents: (displayed_amount if kind == "informational"), category_name: text(raw[:category_name], 120), stack_key: text(raw[:stack_key], 40), external_id: text(raw[:external_id], 120), splits: Array(raw[:splits]).first(HouseholdFinance::DocumentTransactionDraftPersister::MAX_SPLITS) }.compact_blank
      }
    end

    def limitation_codes(values)
      Array(values).map { |value| EXTRACTION_LIMITATIONS.include?(value.to_s) ? value.to_s : "extractor_reported_limitation" }.uniq
    end

    def source_fields(raw, keys)
      raw.slice(*keys).transform_values { |value| text(value, 80) }.compact_blank
    end

    def integer(value)
      return value if value.is_a?(Integer) && value >= 0
      return value.to_i if value.is_a?(String) && value.match?(/\A\d+\z/)

      nil
    end

    def cents(value)
      number = if value.is_a?(Integer)
        value
      elsif value.is_a?(String) && value.match?(/\A-?\d+\z/)
        value.to_i
      end
      number if number && number.abs <= CENT_LIMIT
    end

    def nonnegative_cents(value)
      value = cents(value)
      value if value && value >= 0
    end

    def date(value)
      Date.iso8601(value.to_s) if value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
    rescue ArgumentError
      nil
    end

    def text(value, limit)
      value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish.truncate(limit).presence
    end
  end
end
