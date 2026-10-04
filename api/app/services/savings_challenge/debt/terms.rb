module SavingsChallenge
  module Debt
    module Terms
      KEYS = %i[label as_of_on balance_cents minimum_payment_cents apr_bps due_on promotional_apr_bps promotional_expires_on post_promo_apr_bps rate_segments status].freeze
      RATE_KEYS = %i[label balance_cents apr_bps promotional_expires_on post_promo_apr_bps].freeze
      module_function

      def normalize(value)
        raise ArgumentError, "Review card terms as an object" unless value.is_a?(Hash)
        input = value.deep_symbolize_keys
        Inputs.keys!(input, required: %i[label as_of_on balance_cents minimum_payment_cents apr_bps], optional: KEYS - %i[label as_of_on balance_cents minimum_payment_cents apr_bps])
        raise ArgumentError, "Review the card terms as-of date" if input[:as_of_on].nil?
        rates = input.fetch(:rate_segments, [])
        raise ArgumentError, "Review at most eight separate rate segments" unless rates.is_a?(Array) && rates.length <= 8
        output = { label: label!(input[:label]), as_of_on: date!(input[:as_of_on]),
          balance_cents: cents!(input[:balance_cents]), minimum_payment_cents: cents!(input[:minimum_payment_cents]), apr_bps: apr!(input[:apr_bps]),
          due_on: date!(input[:due_on]), promotional_apr_bps: apr!(input[:promotional_apr_bps]),
          promotional_expires_on: date!(input[:promotional_expires_on]), post_promo_apr_bps: apr!(input[:post_promo_apr_bps]),
          rate_segments: rates.map { |rate| rate!(rate) }, status: input.fetch(:status, "active") }
        raise ArgumentError, "Choose active, paid_off or archived" unless output[:status].in?(%w[active paid_off archived])
        raise ArgumentError, "A paid-off card needs an explicitly reviewed zero balance" if output[:status] == "paid_off" && output[:balance_cents] != 0
        allocated = output[:rate_segments].filter_map { |rate| rate[:balance_cents] }.sum
        raise ArgumentError, "Rate-segment balances exceed the reviewed card balance" if output[:balance_cents] && allocated > output[:balance_cents]
        output.deep_stringify_keys
      end

      def label!(value)
        raise ArgumentError, "Use a card or rate label of one to 120 characters" unless value.instance_of?(String) && value.strip.present? && value.length <= 120
        value
      end

      def cents!(value) = value.nil? ? nil : Inputs.integer!(value, minimum: 0)
      def apr!(value) = value.nil? ? nil : Inputs.integer!(value, minimum: 0, maximum: 100_000)
      def date!(value)
        return nil if value.nil?
        date = Inputs.date!(value)
        raise ArgumentError, "Use a positive four-digit calendar year" unless date.year.between?(1, 9999)
        date.iso8601
      end

      def rate!(value)
        raise ArgumentError, "Review each separate rate as an object" unless value.is_a?(Hash)
        rate = value.deep_symbolize_keys
        Inputs.keys!(rate, required: %i[label balance_cents apr_bps], optional: %i[promotional_expires_on post_promo_apr_bps])
        { label: label!(rate[:label]), balance_cents: cents!(rate[:balance_cents]), apr_bps: apr!(rate[:apr_bps]),
          promotional_expires_on: date!(rate[:promotional_expires_on]), post_promo_apr_bps: apr!(rate[:post_promo_apr_bps]) }
      end
    end
  end
end
