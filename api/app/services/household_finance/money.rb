module HouseholdFinance
  module Money
    # One household-sized ceiling for every participant money input. It keeps
    # values well inside the 32-bit cents columns ($21,474,836.47) and gives one
    # plain-language rule instead of a database error.
    MAX_AMOUNT_CENTS = 999_999_999
    MAX_AMOUNT_TEXT = "$9,999,999.99".freeze
    DOCUMENT_AMOUNT_PATTERN = /\A\$?(?:\d{1,9}|\d{1,3}(?:,\d{3}){1,2})(?:\.\d{1,2})?\z/.freeze
    # Participant chat amounts. Build chat regexes from these sources so "$5k",
    # "$1.5K" and "$3 thousand" read as thousands everywhere, never as $5. The
    # suffix needs a word boundary, so "$5 kids meal" and "$5km" stay $5.
    CHAT_NUMBER_SOURCE = "(?:\\d{1,3}(?:,\\d{3})+|\\d{1,9})(?:\\.\\d{1,2})?"
    CHAT_THOUSANDS_SOURCE = "(?:[kK]\\b|\\s*(?i:thousand)\\b)"
    CHAT_THOUSANDS_SUFFIX = /\s*(?:k|thousand)\z/i.freeze
    CHAT_DOLLAR_AMOUNT_PATTERN = /\$\s*(#{CHAT_NUMBER_SOURCE}(?!\d|,\d)#{CHAT_THOUSANDS_SOURCE}?)/.freeze

    module_function

    # Cents for an amount captured from participant chat ("1,250.50", "5k", "3 thousand").
    def chat_cents(value)
      cents(chat_decimal(value))
    end

    # Plain decimal text for an amount captured from participant chat ("5k" -> "5000").
    def chat_amount_text(value)
      text = value.to_s.strip.delete(",")
      return text unless text.match?(CHAT_THOUSANDS_SUFFIX)

      decimal = chat_decimal(text)
      decimal.frac.zero? ? decimal.to_i.to_s : decimal.to_s("F")
    end

    def chat_decimal(value)
      text = value.to_s.strip.delete(",")
      multiplier = text.match?(CHAT_THOUSANDS_SUFFIX) ? 1000 : 1
      BigDecimal(text.sub(CHAT_THOUSANDS_SUFFIX, "").presence || "0") * multiplier
    rescue ArgumentError
      BigDecimal("0")
    end

    def dollars(cents)
      cents.to_i / 100.0
    end

    def cents(value)
      decimal = BigDecimal(value.to_s.presence || "0")
      (decimal * 100).round.to_i
    rescue ArgumentError
      0
    end

    def cents!(value, message: "Amount must be a number", label: nil)
      text = value.to_s.strip
      raise ArgumentError, message if text.blank?
      raise ArgumentError, message unless text.match?(/\A\d+(?:\.\d+)?\z/)

      whole, fraction = text.split(".", 2)
      ensure_within_limit!(BigDecimal(whole) * 100, label: label || amount_label(message)) if whole.length > 9
      raise ArgumentError, message if fraction.to_s.length > 2

      ensure_within_limit!(cents(value), label: label || amount_label(message))
    end

    def ensure_within_limit!(cents, label: "Amount")
      return cents if cents.to_i.abs <= MAX_AMOUNT_CENTS

      raise ArgumentError, too_large_message(label)
    end

    def too_large_message(label = "Amount")
      "#{label.presence || 'Amount'} must be #{MAX_AMOUNT_TEXT} or less."
    end

    # "Fixed essentials must be a number ..." -> "Fixed essentials"
    def amount_label(message)
      message.to_s[/\A(.+?) (?:must|is|cannot|can't)\b/, 1] || "Amount"
    end

    def document_cents(value, negative_as_magnitude: false, allow_negative: false)
      text = value.to_s.unicode_normalize(:nfkc).strip
      return nil if text.blank?

      accounting_negative = text.match?(/\A\(.*\)\z/)
      text = text[1...-1].to_s.strip if accounting_negative
      signed_negative = text.start_with?("-")
      text = text.delete_prefix("-").strip if signed_negative
      negative = accounting_negative || signed_negative
      return nil if negative && !negative_as_magnitude && !allow_negative

      normalized = text.sub(/\A\$\s+/, "$")
      return nil unless normalized.match?(DOCUMENT_AMOUNT_PATTERN)

      decimal = BigDecimal(normalized.delete("$,"))
      cents = (decimal * 100).to_i
      negative && allow_negative ? -cents : cents
    rescue ArgumentError, FloatDomainError
      nil
    end

    def monthly_cents(amount_cents, cadence)
      annual_cents = annualized_cents(amount_cents, cadence)
      (annual_cents + 6) / 12
    end

    def period_cents(amount_cents, cadence, month:)
      month_number = Integer(month)
      raise ArgumentError, "Month must be between 1 and 12" unless month_number.between?(1, 12)

      base, remainder = annualized_cents(amount_cents, cadence).divmod(12)
      base + (month_number <= remainder ? 1 : 0)
    end

    def annualized_cents(amount_cents, cadence)
      case cadence.to_s
      when "weekly" then amount_cents.to_i * 52
      when "biweekly" then amount_cents.to_i * 26
      when "semi_monthly" then amount_cents.to_i * 24
      when "annual" then amount_cents.to_i
      when "one_time" then 0
      else amount_cents.to_i * 12
      end
    end
  end
end
