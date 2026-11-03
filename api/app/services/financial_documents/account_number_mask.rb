# frozen_string_literal: true

module FinancialDocuments
  # One place that hides long account numbers in text a person reads, keeping the last four digits.
  # Display only: the statement's own words stay stored as read, for audit.
  module AccountNumberMask
    # Not part of an amount ($1234567, 1234567.89) and not the middle of a longer token.
    RUN = /(?<![\d$.,])\d{6,}(?!\d|[.,]\d)/
    # A number the statement already masked ("****1234", "XXXX 1234").
    MASKED = /(?<!\w)(?:\*{2,}|X{2,})\s*(\d{4})\b/i
    # Stored statement text: any run of 8+ digits, whatever sits beside it ("ACCT.123456789012", "ANN,6715551234"),
    # unless it is part of a money amount with a decimal point ("12345678.90").
    STORED = /(?<!\d[.,])\d{8,}(?!\d|[.,]\d)/
    # Eight digits that read as a calendar date near today are a date, not an account number.
    DATE_RUN = /\A\d{8}\z/
    module_function

    # For text kept as evidence: stricter than what a person reads, and masks dates too.
    def stored(text)
      return text if text.nil?
      text.to_s.gsub(STORED) { |digits| "****#{digits.last(4)}" }
    end

    def call(text, min_digits: 6, marker: "····")
      return text if text.nil?
      pattern = min_digits == 6 ? RUN : /(?<![\d$.,])\d{#{min_digits},}(?!\d|[.,]\d)/
      text.to_s.gsub(pattern) { |digits| date_like?(digits) ? digits : "#{marker}#{digits.last(4)}" }
    end

    def date_like?(digits)
      return false unless digits.match?(DATE_RUN)
      day = Date.strptime(digits, "%Y%m%d")
      day.between?(Date.current.advance(years: -10), Date.current.advance(years: 10))
    rescue Date::Error
      false
    end

    # Display text for a person: long numbers and printed masks both read "····1234".
    def display(text)
      return text if text.nil?
      call(text.to_s.gsub(MASKED) { "····#{Regexp.last_match(1)}" })
    end
  end
end
