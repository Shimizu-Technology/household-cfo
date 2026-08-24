module HouseholdFinance
  module Money
    DOCUMENT_AMOUNT_PATTERN = /\A\$?(?:\d{1,9}|\d{1,3}(?:,\d{3}){1,2})(?:\.\d{1,2})?\z/.freeze

    module_function

    def dollars(cents)
      cents.to_i / 100.0
    end

    def cents(value)
      decimal = BigDecimal(value.to_s.presence || "0")
      (decimal * 100).round.to_i
    rescue ArgumentError
      0
    end

    def cents!(value, message: "Amount must be a number")
      text = value.to_s.strip
      raise ArgumentError, message if text.blank?
      raise ArgumentError, message unless text.match?(/\A\d{1,9}(?:\.\d{1,2})?\z/)

      cents(value)
    end

    def document_cents(value, negative_as_magnitude: false)
      text = value.to_s.unicode_normalize(:nfkc).strip
      return nil if text.blank?

      accounting_negative = text.match?(/\A\(.*\)\z/)
      text = text[1...-1].to_s.strip if accounting_negative
      signed_negative = text.start_with?("-")
      text = text.delete_prefix("-").strip if signed_negative
      negative = accounting_negative || signed_negative
      return nil if negative && !negative_as_magnitude

      normalized = text.sub(/\A\$\s+/, "$")
      return nil unless normalized.match?(DOCUMENT_AMOUNT_PATTERN)

      decimal = BigDecimal(normalized.delete("$,"))
      (decimal * 100).to_i
    rescue ArgumentError, FloatDomainError
      nil
    end

    def monthly_cents(amount_cents, cadence)
      case cadence.to_s
      when "weekly"
        (amount_cents.to_i * 52 / 12.0).round
      when "biweekly"
        (amount_cents.to_i * 26 / 12.0).round
      when "semi_monthly"
        amount_cents.to_i * 2
      when "annual"
        (amount_cents.to_i / 12.0).round
      when "one_time"
        0
      else
        amount_cents.to_i
      end
    end
  end
end
