module FinancialDocuments
  module SourceReview
    # What a person calls an account in a sentence. A system label such as "Spreadsheet account 1" is not a name,
    # so it reads as unnamed instead of leaking; the last four digits are kept when the file printed them.
    module AccountName
      GENERIC = /\A(?:(?:(?:spreadsheet|statement|source|tracked|bank)\s+)?account|credit card)(?:\s*#?\d+)?\z/i
      MASKED = /[\s·*•-]*(?:\*{2,}|X{2,}|·{2,}|•{2,})\s*\d{4}\b/i
      TRAILING_DIGITS = /(?:\A|[\s#])(?<last4>\d{4})\z/
      ACCOUNT_NUMBER = /\A\d(?:[ -]?\d){3,}\z/
      module_function

      # Returns { name:, last4: }; either may be nil.
      def parts(label, masked_identifier = nil)
        name = display_label(label)
        last4 = [ display_label(masked_identifier), name ].filter_map do |text|
          text.to_s.scan(MASKED).last&.last(4)
        end.first
        name = name.gsub(MASKED) { |match| match.end_with?(last4.to_s) ? " " : match }.gsub(/\s*·\s*\z/, "").squish
        name = nil if name.blank? || name.match?(GENERIC)
        { name: name, last4: last4 }
      end

      def display_label(label)
        text = label.to_s.squish
        return "····#{text.gsub(/\D/, '').last(4)}" if text.match?(ACCOUNT_NUMBER)
        return text if text.match?(GENERIC)

        AccountNumberMask.display(text).sub(TRAILING_DIGITS) { " ····#{Regexp.last_match[:last4]}" }.strip
      end

      # The name a new account is saved under when she has not given one.
      def default_label(label, masked_identifier, basis)
        parts = parts(label, masked_identifier)
        base = parts[:name] || (basis == "liability" ? "Credit card" : "Bank account")
        parts[:last4] ? "#{base.truncate(111, omission: '').rstrip} ····#{parts[:last4]}" : base
      end
    end
  end
end
