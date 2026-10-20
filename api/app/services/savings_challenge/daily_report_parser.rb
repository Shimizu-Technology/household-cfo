module SavingsChallenge
  # Reads a participant's daily check-in reply ("$8 at Shell and 20 at Payless",
  # "no spend today") into unreviewed card input. It never records anything:
  # the participant checks the card and taps Save, and the server still
  # requires explicit acceptance for every purchase.
  #
  # The result is conservative. Questions, plans, refunds, borrowed money,
  # card or loan payments, savings moves and investments are not purchases,
  # and an unclear day is left to the conversation instead of guessed.
  class DailyReportParser
    Result = Struct.new(:status, :report, keyword_init: true) do
      def found? = status == :found
      # Nothing that looks like a daily report was read; an extractor may try.
      def none? = status == :none
    end

    MAX_PURCHASES = 10
    MERCHANT_LIMIT = 120
    FEELING_LIMIT = 140
    NUMBER_SOURCE = "(?:\\d{1,3}(?:,\\d{3})+|\\d+)(?:\\.\\d{1,2})?".freeze
    MONTHS = { "jan" => 1, "feb" => 2, "mar" => 3, "apr" => 4, "may" => 5, "jun" => 6, "jul" => 7, "aug" => 8, "sep" => 9, "oct" => 10, "nov" => 11, "dec" => 12 }.freeze
    MONTH_SOURCE = "(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\\.?".freeze
    WEEKDAYS = %w[sunday monday tuesday wednesday thursday friday saturday].freeze
    WEEKDAY_SOURCE = "(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday)".freeze

    # A date phrase, captured so its digits are never read as money.
    DATE_PATTERN = Regexp.new(
      "\\b(?<iso>\\d{4}-\\d{2}-\\d{2})\\b" \
      "|\\b(?:on\\s+)?(?<month>#{MONTH_SOURCE})\\s+(?<day>\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s+(?<year>\\d{4}))?\\b" \
      "|\\b(?<today>today|tonight|this\\s+(?:morning|afternoon|evening)|earlier\\s+today)\\b" \
      "|\\b(?<yesterday>yesterday|last\\s+night)\\b" \
      "|\\b(?:on\\s+|last\\s+)?(?<weekday>#{WEEKDAY_SOURCE})\\b",
      Regexp::IGNORECASE
    ).freeze
    # Day references this parser does not resolve; guessing would misdate money.
    UNCLEAR_DATE_PATTERN = /\b(?:last|this|past)\s+(?:week|weekend|month)\b|\bthe\s+other\s+day\b|\b\d+\s+days?\s+ago\b|\bon\s+the\s+\d{1,2}(?:st|nd|rd|th)\b|\bover\s+the\s+weekend\b|\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/i.freeze
    TIME_PATTERN = /\b\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)(?![a-z])|\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*o['’]?clock\b/i.freeze

    QUESTION_OR_PLAN = /\?|\b(?:if|would|could|might|maybe|plan|plans|planning|want(?:ed)?\s+to|wanna|will|won['’]?t|should|shall|going\s+to|gonna|gotta|about\s+to|thinking\s+(?:of|about)|tomorrow|next\s+(?:week|month|time|payday)|hope\s+to|need\s+to|have\s+to|usually|always|every\s+(?:day|week|month)|each\s+(?:day|week|month)|budget(?:ed|ing)?)\b|\bmay\b(?!\s+\d)/i.freeze
    NEGATION = /\b(?:didn['’]?t|did\s+not|haven['’]?t|have\s+not|hasn['’]?t|not\s+yet|never|don['’]?t|do\s+not)\b/i.freeze
    # Money that is not a purchase anywhere in the message.
    NOT_PURCHASE_MESSAGE = /\b(?:refund(?:ed|s)?|returned|reimburs\w*|borrow(?:ed|ing)?|lent|cash\s+advance|payday\s+loan|got\s+paid|salary)\b|\bgot\s+(?:\$?\s*\d[\d,.]*\s+)?back\b/i.freeze
    # A single clause that moves money without buying something.
    NOT_PURCHASE_CLAUSE = /\b(?:pa(?:id|y|yment)|put)\s+(?:\$?\s*\d[\d,.]*\s+)?(?:(?:on|to|toward|towards|into|off|down)\s+)?(?:my\s+|the\s+|our\s+)?(?:credit\s*card|card|visa|mastercard|amex)\b|\b(?:credit\s*card|card)\s+(?:bill|balance|payment)|\b(?:loan|mortgage|car\s+note|debt|minimum\s+payment|transfer(?:red|ring)?|deposit(?:ed)?|withdr(?:ew|awn|awal|aw)|venmo|zelle|cash\s*app|atm|paid\s+back|pay\s+back|owe[ds]?|shares?|stocks?|crypto\w*|bitcoin|btc|etfs?|index\s+funds?|mutual\s+funds?|savings|set\s+aside|put\s+aside|reserved)\b/i.freeze
    SPEND_VERB = /\b(?:spent|paid|bought|purchased|charged|grabbed|dropped|blew|ordered|picked\s+up|got)\b/i.freeze
    # A bare number counts as dollars only after one of these spending verbs.
    BARE_AFTER_VERB = /\b(?:spent|paid|charged|dropped|blew)\s+(?:(?:about|around|like|roughly|almost|over|just|another)\s+)?\z/i.freeze
    # Words that may follow a bare money amount; anything else ("2 kids", "3 times") is not money.
    BARE_FOLLOWERS = /\A(?:\s*(?:dollars?|bucks)\b|\s+(?:at|@|from|on|for|in|today|tonight|yesterday|this|last|earlier|and|then|plus|total|cash|altogether)\b|\s*[.,;!]|\s*\z)/i.freeze
    LEADING_JOINER = /\A(?:(?:and|then|plus|also|another|oh|ok|okay|so|um)\b[\s,]*|(?>~+)\s*)*\z/i.freeze
    DOLLAR_PATTERN = Regexp.new("\\$\\s*(#{NUMBER_SOURCE})(\\s*(?:k\\b|thousand\\b))?|\\b(#{NUMBER_SOURCE})\\s*(?:dollars?|bucks)\\b", Regexp::IGNORECASE).freeze
    BARE_PATTERN = Regexp.new("(?<![\\w.$#,:/-])(#{NUMBER_SOURCE})(?![\\w%.:,/]|\\.\\d)", Regexp::IGNORECASE).freeze
    # "Shell $8", "Payless: 20", "K-Mart - 15.99" on its own line or clause.
    LIST_ITEM = Regexp.new("\\A(?<place>[a-z][^$\\d\\n]{0,60}?)\\s*(?:[:\\-–—]\\s*)?(?<dollar>\\$)?\\s*(?<amount>#{NUMBER_SOURCE})\\s*(?:dollars?|bucks)?\\s*\\z", Regexp::IGNORECASE).freeze
    MERCHANT_STOP = "(?=\\s+(?:today|tonight|yesterday|this\\s+(?:morning|afternoon|evening)|last\\s+night|earlier|on\\s+(?:#{MONTH_SOURCE}|#{WEEKDAY_SOURCE}|\\d+|my|the|a|an|gas|food|groceries|lunch|dinner|breakfast|coffee|snacks)\\b" \
      "|for\\s+(?:\\$|\\d+|my|the|a|an|some|lunch|dinner|breakfast|coffee|gas|food|groceries|snacks|kids?|me|us)" \
      "|at|because|since|cause|cuz|when|while|but|so|with|and|felt|feel|feeling|which|that|after|before)\\b|\\s+\\$|[.,;!?\\n]|\\z)"
    MERCHANT_PATTERN = Regexp.new("(?:\\bat|\\bfrom|@)\\s+(?:the\\s+)?(?<merchant>[a-z0-9][^\\n]*?)#{MERCHANT_STOP}", Regexp::IGNORECASE).freeze
    NOT_A_PLACE = /\A(?:night|noon|lunch(?:\s*time)?|breakfast|dinner|least|first|once|all|most|\d+)\z/i.freeze
    NO_SPEND_PATTERN = Regexp.new(
      "\\b(?:(?:i|we)\\s+)?(?:didn['’]?t|did\\s+not|haven['’]?t|have\\s+not)\\s+(?:spend|spent|buy|bought|purchase)\\s+(?:anything|a\\s+thing|any(?:\\s+money)?|a\\s+(?:single\\s+)?(?:cent|dime|penny|dollar))" \
      "|\\bno[\\s-]+spend(?:ing)?(?:\\s+day)?\\b|\\bspent\\s+(?:nothing|zero|\\$\\s*0(?:\\.00?)?(?![\\d.]))|\\bnothing\\s+spent\\b|\\bno\\s+purchases\\b" \
      "|(?:\\A|\\s)(?:zero|\\$\\s*0(?:\\.00?)?)\\s+(?:spent|spending|today|yesterday)\\b",
      Regexp::IGNORECASE
    ).freeze
    # "I didn't spend anything on clothes" is not a no-spend day.
    SCOPED_NO_SPEND = /\A\s*(?:on|at|for|in)\s+(?!(?:#{MONTH_SOURCE}|#{WEEKDAY_SOURCE}|\d))[a-z]/i.freeze
    FEELING_END = "(?=\\s+(?:when|while|after|but|because|since|and|now|today|about)\\b|[.,;!?\\n]|\\z)"
    FEELING_THEN = Regexp.new("\\b(?:i\\s+)?(?:felt|was\\s+feeling)\\s+(?<feeling>[a-z][^.,;!?\\n]{0,#{FEELING_LIMIT}}?)#{FEELING_END}", Regexp::IGNORECASE).freeze
    FEELING_NOW = Regexp.new("\\bnow\\s+(?:i\\s+)?(?:feel|i['’]?m|i\\s+am|feeling)\\s+(?<feeling>[a-z][^.,;!?\\n]{0,#{FEELING_LIMIT}}?)#{FEELING_END}" \
      "|\\b(?:i\\s+)?(?:feel|i['’]?m\\s+feeling)\\s+(?<feeling2>[a-z][^.,;!?\\n]{0,#{FEELING_LIMIT}}?)\\s+(?:about\\s+it\\s+)?now\\b", Regexp::IGNORECASE).freeze

    def initialize(enrollment, message:)
      @enrollment = enrollment
      @message = message.to_s.unicode_normalize(:nfkc).gsub(/\r\n?/, "\n").strip
    end

    def call
      return result(:excluded) if @message.blank? || @message.length > 2_000
      return result(:excluded) if HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message)
      return result(:excluded) if @message.match?(QUESTION_OR_PLAN) || @message.match?(NOT_PURCHASE_MESSAGE)
      return result(:excluded) if HouseholdFinance::MoneyMovementText.investment_purchase?(@message)

      no_spend = no_spend_date
      return no_spend if no_spend.is_a?(Result)
      return result(:excluded) if @message.match?(NEGATION)

      purchases = read_purchases
      return purchases if purchases.is_a?(Result)
      return result(:none) if purchases.empty?

      report(purchases: purchases, no_spend: false, local_on: today, feelings: self.class.feelings(@message))
    end

    # Optional feelings written in the same message: "felt guilty", "now I feel ok".
    def self.feelings(text)
      value = text.to_s
      when_spent = value[FEELING_THEN, :feeling]
      now_match = value.match(FEELING_NOW)
      now = now_match && (now_match[:feeling] || now_match[:feeling2])
      feelings = { when_spent: clean_feeling(when_spent), now: clean_feeling(now) }
      feelings.values.any? ? feelings : nil
    end

    def self.clean_feeling(value)
      text = value.to_s.squish
      text.present? && text.length <= FEELING_LIMIT ? text : nil
    end

    # Shared field rules for parsed and model-proposed purchases.
    def self.merchant(value)
      text = value.to_s.squish.sub(/[\s,;:.!-]+\z/, "")
      return "" if text.blank? || text.length > MERCHANT_LIMIT || text.include?("$") || text.match?(NOT_A_PLACE)
      return "" if text.match?(/\b\d+\.\d{1,2}\b|\b\d+\s*(?:dollars?|bucks)\b/i)

      text
    end

    def self.cents(text, thousands: false)
      cents = HouseholdFinance::Money.chat_cents("#{text}#{'k' if thousands}")
      cents if cents.between?(1, Daily::Inputs::MAX_AMOUNT_CENTS)
    rescue ArgumentError, TypeError
      nil
    end

    private

    def today = @enrollment.local_today
    def last_open_day = [ @enrollment.ends_on, today ].min

    def result(status, report = nil) = Result.new(status: status, report: report)

    def report(purchases:, no_spend:, local_on:, feelings:)
      result(:found, { kind: "daily_report", local_on: local_on.iso8601,
        purchases: purchases.map { |row| row.merge(purchased_on: row[:purchased_on].iso8601) },
        no_spend: no_spend, feelings: purchases.any? ? feelings : nil, counted: false, approval_state: "unreviewed_input" })
    end

    def no_spend_date
      match = @message.match(NO_SPEND_PATTERN)
      return unless match
      return result(:excluded) if match.post_match.match?(SCOPED_NO_SPEND)
      # A positive amount alongside "no spend" contradicts itself.
      return result(:excluded) if spoken_amounts(@message.sub(match[0], " ")).any?
      return result(:excluded) if @message.match?(UNCLEAR_DATE_PATTERN)

      dates = date_tokens(@message).map { |token| token[:date] }.uniq
      return result(:rejected) if dates.length > 1 || dates.include?(nil)
      date = dates.first || today
      return result(:rejected) unless open_day?(date)

      report(purchases: [], no_spend: true, local_on: date, feelings: nil)
    end

    def read_purchases
      return result(:rejected) if @message.match?(UNCLEAR_DATE_PATTERN)

      segments = split_segments(@message)
      verb = @message.match?(SPEND_VERB)
      list_like = segments.count { |segment| segment.match?(LIST_ITEM) } >= 2
      rows = []
      skipped = false
      segments.each do |segment|
        if segment.match?(NOT_PURCHASE_CLAUSE)
          skipped = true
          next
        end

        dates = date_tokens(segment)
        amounts = segment_amounts(segment, dates, verb: verb, list_like: list_like)
        next if amounts.empty?
        return result(:rejected) if dates.map { |token| token[:date] }.uniq.length > 1 || dates.any? { |token| token[:date].nil? }

        merchant = amounts.length == 1 ? merchant_for(segment) : ""
        amounts.each { |cents| rows << { amount_cents: cents, merchant: merchant, date: dates.first&.fetch(:date) } }
      end
      # A card payment or savings move alone is not an unread purchase.
      return skipped ? result(:excluded) : [] if rows.empty?
      return result(:rejected) if rows.length > MAX_PURCHASES

      purchases = assign_dates(rows)
      return result(:rejected) unless purchases.all? { |row| open_day?(row[:purchased_on]) }

      purchases
    end

    # A clause without its own day shares the nearest earlier one, else the
    # next one ("$8 at Shell and $20 at Payless yesterday"), else today.
    def assign_dates(rows)
      rows.each_with_index.map do |row, index|
        date = row[:date] || rows[0...index].reverse.find { |other| other[:date] }&.fetch(:date) ||
          rows[(index + 1)..].find { |other| other[:date] }&.fetch(:date) || today
        { amount_cents: row[:amount_cents], merchant: row[:merchant], purchased_on: date }
      end
    end

    def open_day?(date) = date && date >= @enrollment.starts_on && date <= last_open_day

    def split_segments(text)
      text.split(/\n+|;|(?<=[.!])\s+|,(?!\d{3}(?!\d))\s*|\s+(?:and|then|plus|also)\s+(?=\S)/i)
        .map { |segment| segment.squish.sub(/[.!]+\z/, "") }.reject(&:blank?)
    end

    def segment_amounts(segment, dates, verb:, list_like:)
      masked = mask(segment, dates)
      dollars = []
      masked.scan(DOLLAR_PATTERN) do
        match = Regexp.last_match
        dollars << self.class.cents(match[1] || match[3], thousands: match[2].present?)
      end
      return dollars.compact if dollars.any?

      list = segment.match(LIST_ITEM)
      if list && !segment.match?(SPEND_VERB) && !segment.match?(/\b(?:at|from)\b/i)
        return [] unless list[:dollar] || verb || list_like
        return [] if list[:place].squish.match?(/\A(?:i|we|my|our|the|a|an|kids?|children|people)\b/i)

        cents = self.class.cents(list[:amount])
        return cents ? [ cents ] : []
      end
      bare_amounts(masked, verb: verb)
    end

    # Dates and times are masked so "Oct 20" or "at 5pm" is never read as dollars.
    def mask(segment, dates)
      masked = segment.dup
      dates.each { |token| masked[token[:range]] = "~" * token[:range].size }
      masked.gsub(TIME_PATTERN) { |time| "~" * time.length }
    end

    def bare_amounts(masked, verb:)
      amounts = []
      masked.scan(BARE_PATTERN) do
        match = Regexp.last_match
        before = masked[0...match.begin(0)]
        after = masked[match.end(0)..]
        next unless after.match?(BARE_FOLLOWERS)
        next if before.match?(/\b(?:at|on|in|by|around|about|from|until|til|till|after|before|over|under|of|x)\s*\z/i) && !before.match?(BARE_AFTER_VERB)

        money = before.match?(BARE_AFTER_VERB) ||
          (before.match?(LEADING_JOINER) && (verb || after.match?(/\A[^$\d]*?\s(?:at|@|from)\s+[a-z]/i))) ||
          (before.match?(/\bfor\s*\z/i) && verb)
        next unless money

        cents = self.class.cents(match[1])
        amounts << cents if cents
      end
      amounts
    end

    def merchant_for(segment)
      match = segment.match(MERCHANT_PATTERN)
      return self.class.merchant(match[:merchant]) if match

      list = segment.match(LIST_ITEM)
      return "" unless list && !segment.match?(SPEND_VERB) && !list[:place].squish.match?(/\A(?:i|we|my|our|the|a|an)\b/i)

      self.class.merchant(list[:place])
    end

    def date_tokens(text)
      tokens = []
      text.scan(DATE_PATTERN) do
        match = Regexp.last_match
        tokens << { range: match.begin(0)...match.end(0), date: resolve(match) }
      end
      tokens
    end

    def resolve(match)
      return Date.iso8601(match[:iso]) if match[:iso]
      return today if match[:today]
      return today - 1 if match[:yesterday]
      if match[:weekday]
        index = WEEKDAYS.index { |name| name.start_with?(match[:weekday].downcase[0, 3]) }
        return today - ((today.wday - index) % 7)
      end
      month = MONTHS.fetch(match[:month].downcase[0, 3])
      year = match[:year]&.to_i || today.year
      date = Date.new(year, month, match[:day].to_i)
      match[:year] || date <= today ? date : Date.new(year - 1, month, match[:day].to_i)
    rescue Date::Error, ArgumentError
      nil
    end

    # Positive spoken amounts anywhere, used only to detect contradictions.
    def spoken_amounts(text)
      masked = mask(text, date_tokens(text))
      dollars = masked.scan(DOLLAR_PATTERN).filter_map { |captures| self.class.cents(captures[0] || captures[2]) }
      dollars + bare_amounts(masked, verb: text.match?(SPEND_VERB))
    end
  end
end
