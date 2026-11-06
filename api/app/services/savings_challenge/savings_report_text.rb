module SavingsChallenge
  # Read the savings clause, not a nearby purchase amount. Keep a negative
  # statement separate so it cannot negate an otherwise completed purchase.
  module SavingsReportText
    MOVE = "(?:save[ds]?|set aside|put aside|put away|reserve[ds]?)".freeze
    ZERO = '(?:nothing|zero|no(?: new)? money|not a (?:cent|penny)|\\$?0(?:\\.0{1,2})?(?![\\d.]))'.freeze
    NO_SAVINGS = /\b(?:(?:(?:i|we)\s+)?#{MOVE}\s+#{ZERO}|(?:no|nothing|zero)\s+(?:money\s+)?(?:saved|set aside|put aside)|(?:(?:i|we)\s+)?(?:didn['’]?t|did not|haven['’]?t|have not|couldn['’]?t|could not|can['’]?t|cannot|wasn['’]?t able to|was not able to)\s+#{MOVE}\b[^.!?;]*?(?=\s+(?:but|and)\s+(?:(?:i|we)\s+)?(?:spent|bought|paid|purchased|saved|set aside)\b|[.!?;]|\z)|(?:(?:i|we)\s+)?wanted\s+to\s+#{MOVE}\b[^.!?;]*?\bbut\s+(?:(?:i|we)\s+)?(?:couldn['’]?t|could not|can['’]?t|cannot|wasn['’]?t able to|was not able to))(?:(?:\s+anything|\s+any money|\s+today|\s+yesterday))*/i.freeze

    module_function

    def nothing_set_aside?(message)
      text = message.to_s
      return false unless text.match?(NO_SAVINGS)
      positive = purchase_text(text).scan(/\b(?:saved|set aside|put aside|reserved)\s+\$\s*(#{HouseholdFinance::Money::CHAT_NUMBER_SOURCE}#{HouseholdFinance::Money::CHAT_THOUSANDS_SOURCE}?)/i).flatten
      positive.none? { |amount| HouseholdFinance::Money.chat_cents(amount).positive? }
    end

    def purchase_text(message)
      # Stop negative clauses at a contrast introducing a completed purchase.
      text = message.to_s.gsub(NO_SAVINGS) do |clause|
        purchase = clause.match(/\b(?:but|and)\s+(?:(?:i|we)\s+)?(?:spent|bought|paid|purchased)\b/i)
        purchase ? clause[purchase.begin(0)..].sub(/\A(?:but|and)\s+/i, "") : " "
      end
      text.gsub(/(?:\band\b|\bbut\b)\s*(?=[.!;]|\z)/i, " ").sub(/\A\s*(?:and|but)\s+/i, "").strip
    end
  end
end
