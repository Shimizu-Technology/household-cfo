# frozen_string_literal: true

module FinancialDocuments
  # One place that hides long account numbers in text a person reads, keeping the last four digits.
  # Display only: the statement's own words stay stored as read, for audit.
  module AccountNumberMask
    # Not part of an amount ($1234567, 1234567.89) and not the middle of a longer token.
    RUN = /(?<![\d$.,])\d{6,}(?!\d|[.,]\d)/
    # A number the statement already masked ("****1234", "XXXX 1234").
    MASKED = /(?<!\w)(?:\*{2,}|X{2,})\s*(\d{4})\b/i
    module_function

    def call(text, min_digits: 6, marker: "····")
      return text if text.nil?
      pattern = min_digits == 6 ? RUN : /(?<![\d$.,])\d{#{min_digits},}(?!\d|[.,]\d)/
      text.to_s.gsub(pattern) { |digits| "#{marker}#{digits.last(4)}" }
    end

    # Display text for a person: long numbers and printed masks both read "····1234".
    def display(text)
      return text if text.nil?
      call(text.to_s.gsub(MASKED) { "····#{Regexp.last_match(1)}" })
    end
  end
end
