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
