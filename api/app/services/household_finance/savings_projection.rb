# frozen_string_literal: true

require "date"

module HouseholdFinance
  # Projects one enrollment's already-authorized current approved version heads.
  # Source events, draft revisions and older approved versions are not money entries.
  class SavingsProjection
    CALCULATION_VERSION = 1
    ELIGIBLE_FUNDING_SOURCES = %w[earned_income gift bonus new_money_reserved].freeze
    EXCLUDED_FUNDING_SOURCES = %w[preexisting borrowed cash_advance existing_internal_money].freeze
    FUNDING_SOURCES = (ELIGIBLE_FUNDING_SOURCES + EXCLUDED_FUNDING_SOURCES + [ "withdrawal" ]).freeze
    ENTRY_KEYS = %i[logical_entry_id version_id approval_state current_head effective_on signed_cents currency funding_source evidence_supported_cents].freeze

    class InvalidInput < ArgumentError
      attr_reader :code

      def initialize(code)
        @code = code
        super("Invalid savings projection input: #{code}")
      end
    end

    def initialize(entries:, cutoff_on:, target_cents: nil, reporting_known: false, zero_attested: false)
      @entries = entries
      @cutoff_on = cutoff_on
      @target_cents = target_cents
      @reporting_known = reporting_known
      @zero_attested = zero_attested
    end

    def call
      validate_options!
      entries = normalized_entries
      approved = entries.select { |entry| entry[:approval_state] == "approved" && entry[:effective_on] <= @cutoff_on }
        .sort_by { |entry| [ entry[:effective_on], entry[:logical_entry_id] ] }
      eligible, excluded = approved.partition { |entry| eligible?(entry) }
      net = eligible.sum { |entry| entry[:signed_cents] }
      validate_reporting!(eligible, net)
      supported = supported_remaining(eligible)
      invalid!("support_exceeds_positive_net") if supported > [ net, 0 ].max

      {
        calculation_version: CALCULATION_VERSION,
        cutoff_on: @cutoff_on.iso8601.freeze,
        reporting_known: @reporting_known,
        zero_attested: @zero_attested,
        reported_cents: @reporting_known ? net : nil,
        evidence_supported_cents: @reporting_known ? supported : nil,
        target_cents: @target_cents,
        achieved: progress_known? ? net >= @target_cents : nil,
        progress_basis_points: progress_known? ? ([ [ net, 0 ].max, @target_cents ].min * 10_000).div(@target_cents) : nil,
        contribution_cents: @reporting_known ? eligible.sum { |entry| [ entry[:signed_cents], 0 ].max } : nil,
        withdrawal_cents: @reporting_known ? eligible.sum { |entry| [ -entry[:signed_cents], 0 ].max } : nil,
        included_entry_count: eligible.length,
        excluded_entry_count: excluded.length,
        pending_entry_count: entries.count { |entry| entry[:approval_state] == "draft" && entry[:effective_on] <= @cutoff_on },
        included_version_ids: eligible.map { |entry| entry[:version_id] }.freeze
      }.freeze
    end

    private

    def validate_options!
      invalid!("entries_must_be_array") unless @entries.instance_of?(Array)
      @cutoff_on = date!(@cutoff_on)
      invalid!("target_must_be_positive_integer_or_nil") unless @target_cents.nil? || (@target_cents.instance_of?(Integer) && @target_cents.positive?)
      invalid!("reporting_known_must_be_boolean") unless boolean?(@reporting_known)
      invalid!("zero_attested_must_be_boolean") unless boolean?(@zero_attested)
      invalid!("unknown_cannot_attest_zero") if @zero_attested && !@reporting_known
    end

    def normalized_entries
      entries = @entries.map { |entry| normalized_entry(entry) }
      invalid!("duplicate_version_id") unless entries.map { |entry| entry[:version_id] }.uniq.length == entries.length
      approved = entries.select { |entry| entry[:approval_state] == "approved" }
      invalid!("duplicate_approved_logical_head") unless approved.map { |entry| entry[:logical_entry_id] }.uniq.length == approved.length
      entries
    end

    def normalized_entry(entry)
      invalid!("entry_keys_must_match_contract") unless entry.instance_of?(Hash) && entry.keys.length == ENTRY_KEYS.length && (entry.keys - ENTRY_KEYS).empty?
      logical_id = identity!(entry[:logical_entry_id])
      version_id = identity!(entry[:version_id])
      invalid!("invalid_approval_state") unless %w[approved draft].include?(entry[:approval_state])
      invalid!("current_head_must_be_boolean") unless boolean?(entry[:current_head])
      invalid!("approved_version_is_not_current_head") if entry[:approval_state] == "approved" && !entry[:current_head]
      invalid!("unsupported_currency") unless entry[:currency] == "USD"
      amount = entry[:signed_cents]
      support = entry[:evidence_supported_cents]
      invalid!("signed_cents_must_be_integer") unless amount.instance_of?(Integer)
      invalid!("support_must_be_nonnegative_integer") unless support.instance_of?(Integer) && support >= 0
      invalid!("invalid_funding_source") unless FUNDING_SOURCES.include?(entry[:funding_source])
      if entry[:funding_source] == "withdrawal"
        invalid!("withdrawal_must_be_nonpositive") if amount.positive?
        invalid!("withdrawal_cannot_add_support") unless support.zero?
      else
        invalid!("contribution_must_be_nonnegative") if amount.negative?
        invalid!("support_exceeds_contribution") if support > amount
      end
      entry.merge(logical_entry_id: logical_id, version_id: version_id, effective_on: date!(entry[:effective_on]))
    end

    def validate_reporting!(eligible, net)
      invalid!("empty_known_ledger_requires_zero_attestation") if @reporting_known && eligible.empty? && !@zero_attested
      invalid!("zero_attestation_conflicts_with_net") if @zero_attested && !net.zero?
    end

    def supported_remaining(entries)
      lots = []
      first_lot = 0
      carry = 0
      entries.each do |entry|
        if entry[:signed_cents] >= 0
          lot = { supported: entry[:evidence_supported_cents], unsupported: entry[:signed_cents] - entry[:evidence_supported_cents] }
          carry = consume!(lot, carry)
          lots << lot
        else
          remaining = -entry[:signed_cents]
          while remaining.positive? && first_lot < lots.length
            remaining = consume!(lots[first_lot], remaining)
            first_lot += 1 if lots[first_lot].values.sum.zero?
          end
          carry += remaining
        end
      end
      lots.sum { |lot| lot[:supported] }
    end

    # Conservative reporting allocation: support is consumed before unsupported
    # cents within a lot. Carry from earlier withdrawals follows the same rule.
    def consume!(lot, amount)
      %i[supported unsupported].each do |kind|
        consumed = [ lot[kind], amount ].min
        lot[kind] -= consumed
        amount -= consumed
      end
      amount
    end

    def eligible?(entry)
      ELIGIBLE_FUNDING_SOURCES.include?(entry[:funding_source]) || entry[:funding_source] == "withdrawal"
    end

    def progress_known?
      @reporting_known && !@target_cents.nil?
    end

    def date!(value)
      return value if value.instance_of?(Date)
      invalid!("date_must_be_date_or_iso_string") unless value.instance_of?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)
      Date.iso8601(value)
    rescue Date::Error
      invalid!("invalid_calendar_date")
    end

    def identity!(value)
      invalid!("identity_must_be_stable_string") unless value.instance_of?(String) && value.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,127}\z/)
      value.dup.freeze
    end

    def boolean?(value)
      value == true || value == false
    end

    def invalid!(code)
      raise InvalidInput, code
    end
  end
end
