module SavingsChallenge
  # A bounded vocabulary for dollar amounts in a goal conversation. Other
  # financial input keeps its own parser; a weekly pace is never saved money.
  module GoalAmount
    ONES = %w[zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen].freeze
    TENS = %w[twenty thirty forty fifty sixty seventy eighty ninety].freeze
    SMALL = "(?:#{ONES.drop(1).join('|')}|(?:#{TENS.join('|')})(?:[ -](?:#{ONES[1..9].join('|')}))?)".freeze
    HUNDREDS = "(?:(?:#{ONES[1..9].join('|')}|a) hundred(?: (?:and )?#{SMALL})?|#{SMALL})".freeze
    WORDS = /\b(?:(?:#{HUNDREDS}|a) thousand(?: (?:and )?#{HUNDREDS})?|#{HUNDREDS})\b/i.freeze
    WEEKLY = /\b(?:a|per|each|every)\s+week\b|\bweekly\b/i.freeze
    DEFAULT_PROPOSAL_CENTS = 50_000
    PROPOSAL_RANGE_CENTS = (10_000..100_000).freeze

    # A goal for the pattern she picked: what it frees each month over the
    # three months of the challenge, as a friendly figure. Anything that is
    # not a real monthly figure keeps the standard $500 suggestion.
    def self.pattern_goal(monthly_cents)
      monthly = Integer(monthly_cents, exception: false)
      return { goal_cents: DEFAULT_PROPOSAL_CENTS, scaled: false } unless monthly&.positive?

      raw = monthly * 3
      step = raw > 50_000 ? 10_000 : 5_000
      goal = ((raw + step / 2) / step) * step
      { goal_cents: goal.clamp(PROPOSAL_RANGE_CENTS.begin, PROPOSAL_RANGE_CENTS.end), raw_cents: raw, scaled: true }
    end

    def self.normalize(message)
      message.gsub(WORDS) do |words|
        total = part = 0
        words.downcase.tr("-", " ").split.each do |word|
          if word == "thousand"
            total += part * 1000
            part = 0
          elsif word == "hundred"
            part *= 100
          elsif word != "and"
            part += word == "a" ? 1 : ONES.index(word) || (TENS.index(word) + 2) * 10
          end
        end
        (total + part).to_s
      end
    end
  end
end
