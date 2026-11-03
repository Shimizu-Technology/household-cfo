module FinancialDocuments
  module SourceReview
    # What a person calls an account in a sentence. A system label such as "Spreadsheet account 1" is not a name,
    # so it reads as unnamed instead of leaking; the last four digits are kept when the file printed them.
    module AccountName
      GENERIC = /\A(?:(?:(?:spreadsheet|statement|source|tracked|bank)\s+)?account|credit card)(?:\s*#?\d+)?\z/i
      MASKED = /[\s·*•-]*(?:\*{2,}|X{2,}|·{2,}|•{2,})\s*\d{4}\b/i
      module_function

      # Returns { name:, last4: }; either may be nil.
      def parts(label, masked_identifier = nil)
        last4 = [ masked_identifier, label ].filter_map { |text| text.to_s[/(?:\*{2,}|X{2,}|·{2,}|•{2,})\s*(\d{4})\b/i, 1] }.first
        name = label.to_s.gsub(MASKED, " ").gsub(/\s*·\s*\z/, "").squish
        name = nil if name.blank? || name.match?(GENERIC)
        { name: name, last4: last4 }
      end

      # The name a new account is saved under when she has not given one.
      def default_label(label, masked_identifier, basis)
        parts = parts(label, masked_identifier)
        base = parts[:name] || (basis == "liability" ? "Credit card" : "Bank account")
        parts[:last4] ? "#{base} ····#{parts[:last4]}" : base
      end
    end
  end
end
