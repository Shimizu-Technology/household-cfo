module SavingsChallenge
  # Classify each clause before extracting money. Negation and intention govern
  # their own action; an amount in a neighbouring clause is never borrowed.
  module SavingsReportText
    SAVE = /\b(?:save[ds]?|saving|set aside|put aside|put away|reserve[ds]?)\b/i.freeze
    WITHDRAW = /\b(?:withdr(?:ew|awn)|took|pulled)\b/i.freeze
    NEGATIVE = /\b(?:not|never|nothing|no|zero|didn['’]?t|haven['’]?t|couldn['’]?t|can['’]?t|cannot|could not|can not|wasn['’]?t|was not)\b/i.freeze
    ZERO = /\b(?:nothing|zero|no(?: new)? money|not a (?:cent|penny))\b|\$0(?:\.0{1,2})?(?![\d.])/i.freeze
    INTENTION = /\b(?:if|suppose|would|could|might|plan(?:ning)?|want(?:ed)?|hope[ds]?|will|should|try|trying|thought|thinking|not yet|tomorrow|next)\b/i.freeze
    MONEY = /\$\s*(#{HouseholdFinance::Money::CHAT_NUMBER_SOURCE}#{HouseholdFinance::Money::CHAT_THOUSANDS_SOURCE}?)/i.freeze
    PLAIN_WORDS = /\A(?:(?:i|we|have|had|did|was|were|am|are|not|able|to|can|could|today|yesterday|later|just|only|any|anything|a|cent|penny|dollars?|bucks|money|new|saved?|saving|set|put|aside|away|reserved?|nothing|no|zero|wanted|but|couldn['’]?t|didn['’]?t|haven['’]?t|can['’]?t|cannot|wasn['’]?t)|\$?\d[\d,.]*)[\s.!]*\z/i.freeze

    module_function

    def clauses(message)
      HouseholdFinance::PurchaseReportText.normalize(message).split(/,(?!\d)|\.(?!\d)|(?<!\d)\.|[;!?]|\b(?:but|and|then|plus)\b/i).map(&:strip).reject(&:empty?)
    end

    def saving_clause?(clause)
      clause.match?(SAVE) || HouseholdFinance::MoneyMovementText.savings_deposit?(clause)
    end

    def withdrawal_clause?(clause)
      clause.match?(WITHDRAW) && clause.match?(/\b(?:savings|reserved|set aside)\b/i)
    end

    def completed?(clause)
      action = clause.match(SAVE) || clause.match(WITHDRAW) || clause.match(/\b#{HouseholdFinance::MoneyMovementText::SAVINGS_DEPOSIT_VERB_SOURCE}\b/i)
      return false unless action
      return false if action[0].downcase.in?(%w[save saving reserve])
      prefix = clause[0...action.begin(0)]
      return false if prefix.match?(NEGATIVE) || prefix.match?(INTENTION) || prefix.match?(HouseholdFinance::MoneyMovementText::NOT_DONE_PREFIX_PATTERN)
      return false if clause.match?(ZERO) || clause.match?(HouseholdFinance::MoneyMovementText::RECURRING_OR_BUDGET_PATTERN)
      return false if clause.match?(/\b(?:refund|borrowed|cash advance|credit card payment)\b/i)
      # "saved $20 with coupons" is a discount, not money reserved.
      !clause.match?(/\b(?:coupons?|discount|sale|off|at)\b/i)
    end

    def movements(message)
      return [] if message.to_s.include?("?")
      clauses(message).filter_map do |clause|
        next unless (saving_clause?(clause) || withdrawal_clause?(clause)) && completed?(clause)
        amounts = clause.scan(MONEY).flatten
        next unless amounts.one?
        cents = HouseholdFinance::Money.chat_cents(amounts.sole)
        next unless cents.between?(1, 2_147_483_647)
        { kind: withdrawal_clause?(clause) ? "withdrawal" : "contribution", amount_cents: cents, clause: clause }
      end
    end

    def nothing_set_aside?(message)
      return false if movements(message).any?
      parts = clauses(message)
      parts.each_with_index.any? do |clause, index|
        (saving_clause?(clause) && (clause.match?(NEGATIVE) || clause.match?(ZERO))) ||
          (index.positive? && clause.match?(NEGATIVE) && parts[index - 1].match?(INTENTION) && saving_clause?(parts[index - 1]))
      end
    end

    def plain_nothing_set_aside?(message)
      return false if message.to_s.include?("?") || !nothing_set_aside?(message)
      # Only the bare fact qualifies. Reasons, feelings, limits and requests all
      # go through the coach, regardless of the words used to express them.
      words = message.to_s.split
      words.all? { |word| word.match?(PLAIN_WORDS) }
    end

    def purchase_text(message)
      clauses(message).reject { |clause| saving_clause?(clause) || withdrawal_clause?(clause) || clause.match?(/\A(?:i|we)?\s*(?:couldn['’]?t|could not|can['’]?t|cannot)\z/i) }.join(". ")
    end
  end
end
