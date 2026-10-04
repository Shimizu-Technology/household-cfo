module Mia
  class FinancialReadOnlyRequest
    # These prohibit changes to the whole financial picture. A limited exclusion
    # such as "do not change income, but set Groceries" is not a global ban.
    PATTERN = /\b(?:do not|don['’]?t|never)\s+(?:(?:change|update|save|record|apply|edit|alter)\s+anything|make\s+(?:any\s+)?changes)\b|\b(?:read-only|read only (?:question|analysis|request)|explain\s+only)\b|(?:\A|[.!?;])\s*(?:please[,\s]+)?no\s+changes(?:\s*,?\s*please)?(?=\s*(?:[.!?,;]|\z))/i.freeze

    def self.matches?(message)
      message.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "").squish.match?(PATTERN)
    end
  end
end
