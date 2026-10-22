module HouseholdFinance
  # Reads a participant's daily check-in reply ("$8 at Shell and 20 at Payless",
  # "no spend today") into unreviewed card input. It never records anything:
  # the participant checks the card and taps Save, and the server still
  # requires explicit acceptance for every purchase.
  #
  # The result is conservative. Questions, plans, refunds, borrowed money,
  # card or loan payments, savings moves and investments are not purchases,
  # and an unclear day is left to the conversation instead of guessed.
  class PurchaseReportParser
    # reason explains a rejected day ({ kind: :before_start | :after_end | :future, date:, ... }).
    Result = Struct.new(:status, :report, :reason, :source_texts, keyword_init: true) do
      def found? = status == :found
      # Nothing that looks like a daily report was read; an extractor may try.
      def none? = status == :none
    end

    Calendar = Struct.new(:starts_on, :ends_on, :local_today)

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
    UNCLEAR_DATE_PATTERN = /\b(?:january|february|march|april|june|july|august|september|october|november|december)\b(?!\.?\s*\d)|\b(?:in|during|since|last|this)\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sept?|oct|nov|dec)\b(?!\.?\s*\d)|\b(?:last|this|past)\s+(?:week|weekend|month)\b|\bthe\s+other\s+day\b|\b\d+\s+days?\s+ago\b|\bon\s+the\s+\d{1,2}(?:st|nd|rd|th)\b|\bover\s+the\s+weekend\b|\b\d{1,2}\/\d{1,2}(?:\/\d{2,4})?\b/i.freeze
    TIME_PATTERN = /\b\d{1,2}(?::\d{2})?\s*(?:a\.?m\.?|p\.?m\.?)(?![a-z])|\b\d{1,2}:\d{2}\b|\b\d{1,2}\s*o['’]?clock\b/i.freeze

    QUESTION_OR_PLAN = /\?|\b(?:if|would|could|might|maybe|plan|plans|planning|want(?:ed)?\s+to|wanna|will|won['’]?t|should|shall|going\s+to|gonna|gotta|about\s+to|thinking\s+(?:of|about)|tomorrow|next\s+(?:week|month|time|payday)|hope\s+to|need\s+to|have\s+to|usually|always|every\s+(?:day|week|month)|each\s+(?:day|week|month)|budget(?:ed|ing)?)\b|\bmay\b(?!\s+\d)/i.freeze
    COMMAND_REQUEST = /(?:\A|[,;.!]\s*|\band\s+)(?:please\s+)?(?:set|move|create|add|update|increase|reduce|lower|raise|delete|remove|clear|schedule|archive|restore|make|change)\b/i.freeze
    NEGATION = /\b(?:didn['’]?t|did\s+not|haven['’]?t|have\s+not|hasn['’]?t|not\s+yet|never|don['’]?t|do\s+not)\b/i.freeze
    # Money that is not a purchase anywhere in the message.
    NOT_PURCHASE_MESSAGE = /\b(?:refund(?:ed|s)?|returned|reimburs\w*|borrow(?:ed|ing)?|lent|cash\s+advance|payday\s+loan|got\s+paid|salary)\b|\bgot\s+(?:\$?\s*\d[\d,.]*\s+)?back\b|\d[\d,.]*\s*(?:million|billion|mil|bn)\b/i.freeze
    # A single clause that moves money without buying something.
    NOT_PURCHASE_CLAUSE = /\b(?:pa(?:id|y|yment)|put)\s+(?:\$?\s*\d[\d,.]*\s+)?(?:(?:on|to|toward|towards|into|off|down)\s+)?(?:my\s+|the\s+|our\s+)?(?:credit\s*card|card|visa|mastercard|amex)\b|\b(?:credit\s*card|card)\s+(?:bill|balance|payment)|\b(?:loan|mortgage|car\s+note|debt|minimum\s+payment|transfer(?:red|ring)?|deposit(?:ed)?|withdr(?:ew|awn|awal|aw)|venmo|zelle|cash\s*app|atm|paid\s+back|pay\s+back|owe[ds]?|shares?|stocks?|crypto\w*|bitcoin|btc|etfs?|index\s+funds?|mutual\s+funds?|savings|set\s+aside|put\s+aside|reserved|saved|save|saving)\b/i.freeze
    # Money moved into savings is never a purchase ("Got $50 and put it in savings").
    INTO_SAVINGS = /\b(?:put|moved|transferred|deposited|added|stashed|dropped)\b[^.;\n]{0,40}\b(?:in|into|to)\s+(?:my\s+|the\s+|our\s+)?(?:savings|challenge)\b/i.freeze
    # Money talk that is not something bought: goals, income, balances, prices.
    NOT_SPENDING_CLAUSE = /\b(?:goal|target|save\s+for|saving\s+for|pay\s*check|salary|income|earned|earn|earns|balance|gave\s+me|give\s+me|gives\s+me|won|found|went\s+up|goes\s+up|go\s+up|prices?|worth)\b/i.freeze
    # Without its own spending verb, a clause with these is a total, a share or money on hand.
    AMOUNT_ASIDE_CLAUSE = /\b(?:total|totals|altogether|of\s+(?:it|that|this|them)|was\s+for|were\s+for|have|has|had|left|wallet|purse)\b/i.freeze
    # "2 for 1", "buy one get one": a deal, never the price paid.
    DEAL_PATTERN = /\b\d+\s+for\s+\d+(?![\d.])(?!\s*(?:dollars?|bucks))|\bbuy\s+(?:one|1)\s+get\s+(?:one|1)\b|\bbogo\b/i.freeze
    SPEND_VERB = /\b(?:spent|paid|bought|purchased|charged|grabbed|dropped|blew|ordered|picked\s+up|got)\b/i.freeze
    # A bare number counts as dollars only after one of these spending verbs.
    BARE_AFTER_VERB = /\b(?:spent|paid|charged|dropped|blew)\s+(?:(?:about|around|like|roughly|almost|over|just|another)\s+)?\z/i.freeze
    # Words that may follow a bare money amount; anything else ("2 kids", "3 times") is not money.
    BARE_FOLLOWERS = /\A(?:\s*(?:dollars?|bucks)\b|\s+(?:at|@|from|on|for|in|today|tonight|yesterday|this|last|earlier|and|then|plus|total|cash|altogether)\b|\s*[.,;!]|\s*\z)/i.freeze
    LEADING_JOINER = /\A(?:(?:and|then|plus|also|another|oh|ok|okay|so|um)\b[\s,]*|(?>~+)\s*)*\z/i.freeze
    DOLLAR_PATTERN = Regexp.new("\\$\\s*(#{NUMBER_SOURCE})(\\s*(?:k\\b|thousand\\b))?|\\b(#{NUMBER_SOURCE})\\s*(?:dollars?|bucks)\\b", Regexp::IGNORECASE).freeze
    BARE_PATTERN = Regexp.new("(?<![\\w.$#,:/-])(#{NUMBER_SOURCE}(?:k\\b|\\s*thousand\\b)?)(?![\\w%.:,/]|\\.\\d)", Regexp::IGNORECASE).freeze
    # "Shell $8", "Payless: 20", "K-Mart - 15.99" on its own line or clause.
    LIST_ITEM = Regexp.new("\\A(?<place>[a-z][^$\\d\\n]{0,60}?)\\s*(?:[:\\-–—]\\s*)?(?<dollar>\\$)?\\s*(?<amount>#{NUMBER_SOURCE})\\s*(?:dollars?|bucks)?(?:\\s+(?:for|with)\\s+[^$\\d]*)?\\s*\\z", Regexp::IGNORECASE).freeze
    # A store name ends at a date, a connector, or "for" plus a purpose or budget category
    # ("for Dining Out", "for the kids"). Other "for" words stay: "Ross Dress for Less".
    MERCHANT_STOP = "(?=\\s+(?:today|tonight|yesterday|this\\s+(?:morning|afternoon|evening)|last\\s+(?:night|#{WEEKDAY_SOURCE})|#{WEEKDAY_SOURCE}|earlier|on\\s+(?:#{MONTH_SOURCE}|#{WEEKDAY_SOURCE}|\\d+|my|the|a|an|gas|food|groceries|lunch|dinner|breakfast|coffee|snacks)\\b" \
      "|for\\s+(?:\\$|\\d+|my|the|a|an|some|our|lunch|dinner|breakfast|coffee|gas|fuel|food|groceries|snacks|kids?|me|us|dining(?:\\s+out)?|eating\\s+out|entertainment|household|personal|transport(?:ation)?|utilities|bills?|shopping|clothes|clothing|health|medical|school|work|church|gifts?|pets?|car|rent)\\b" \
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
      @original_message = message.to_s.unicode_normalize(:nfkc).gsub(/\r\n?/, "\n").strip
      @message = PurchaseReportText.normalize(@original_message, preserve_layout: true)
    end

    def call
      return result(:excluded) if @message.blank? || @message.length > 2_000
      return result(:excluded) if HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@original_message)
      return result(:excluded) if self.class.question_or_plan?(@message) || @message.match?(NOT_PURCHASE_MESSAGE) || @message.match?(COMMAND_REQUEST)
      return result(:excluded) if HouseholdFinance::MoneyMovementText.investment_purchase?(@message) || @message.match?(INTO_SAVINGS)

      if @message.include?(PurchaseReportText::UNCLEAR_AMOUNT)
        return Result.new(status: :rejected, reason: { question: "What was the purchase amount in dollars and cents?" })
      end
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

    def self.question_or_plan?(text)
      # May's Cafe, Plan B and Budget Mart are places, not modal verbs or plans.
      # Keep questions, future days and all words outside the merchant intact.
      intent = text.gsub(MERCHANT_PATTERN) do |literal|
        place = Regexp.last_match[:merchant]
        literal.sub(place, place.gsub(/\b(?:may|plans?|planning|budget(?:ed|ing)?)\b/i) { |word| "~" * word.length })
      end
      intent.match?(QUESTION_OR_PLAN)
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
      cents if cents.between?(1, 2_147_483_647)
    rescue ArgumentError, TypeError
      nil
    end

    # Cents of every standalone money amount written in the message, with dates
    # and times masked: "20.99" gives only 2099, "Oct 20" and "2 kids" give none.
    def written_amounts(text = @message)
      masked = mask(text, date_tokens(text))
      found = []
      masked.scan(/(?<![\w.,])(\$\s*)?(#{NUMBER_SOURCE})(?![\w%]|[.,:\/]\d)/) do
        match = Regexp.last_match
        # "$12", "12 bucks", "12 at", or dollars and cents ("14.25 over at Kings").
        next unless match[1] || match[2].match?(/\.\d{2}\z/) || masked[match.end(0)..].match?(BARE_FOLLOWERS)

        cents = self.class.cents(match[2])
        found << cents if cents
      end
      found
    end

    # The one day the message names, or nil when it names none or several.
    def date_reading
      dates = named_dates
      dates.one? ? dates.first : nil
    end

    # Every day the message names (nil marks a day that could not be resolved).
    def named_dates
      date_tokens(@message).map { |token| token[:date] }.uniq
    end

    private

    def today = @enrollment.local_today
    def last_open_day = [ @enrollment.ends_on, today ].min

    def result(status, report = nil) = Result.new(status: status, report: report, source_texts: @purchase_sources)

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
      return window_rejection(date) unless open_day?(date)

      report(purchases: [], no_spend: true, local_on: date, feelings: nil)
    end

    def read_purchases
      return result(:rejected) if @message.match?(UNCLEAR_DATE_PATTERN)

      segments = split_segments(@message).map { |segment| segment.sub(/\s*\binstead\s+of\b.*\z/i, "") }.reject(&:blank?)
      verb = @message.match?(SPEND_VERB)
      list_like = segments.count { |segment| segment.match?(LIST_ITEM) } >= 2
      listed = segments.map { |segment| list_form?(segment) }
      # A short "place amount" list stands on its own when every clause with a
      # number is such a line; anything else needs a spending verb.
      numbered = segments.each_index.select { |index| mask(segments[index], date_tokens(segments[index])).match?(/\d/) }
      list_ok = numbered.any? && numbered.all? { |index| listed[index] }
      rows = []
      unpriced = []
      skipped = false
      verb_seen = false
      spoken_place = nil
      spoken_date = nil
      spoken_range = nil
      context_date = nil
      segments.each_with_index do |segment, index|
        dates = date_tokens(segment)
        return result(:rejected) if dates.map { |token| token[:date] }.uniq.length > 1 || dates.any? { |token| token[:date].nil? }
        explicit_date = dates.first&.fetch(:date)
        context_date = explicit_date if explicit_date
        own_verb = segment.match?(SPEND_VERB)
        if segment.match?(NOT_PURCHASE_CLAUSE) || segment.match?(NOT_SPENDING_CLAUSE) || (segment.match?(AMOUNT_ASIDE_CLAUSE) && !own_verb)
          skipped = true
          verb_seen ||= own_verb
          next
        end
        counted = own_verb || verb_seen || (listed[index] && list_ok)
        verb_seen ||= own_verb
        unless counted
          place = merchant_for(segment)
          if place.present?
            spoken_place = place
            spoken_date = context_date
            spoken_range = @segment_ranges[segment]
          end
          next
        end

        amounts = segment_amounts(segment, dates, verb: verb, list_like: list_like)
        if amounts.empty?
          # "grabbed lunch at Kings, 14.25": a place in the clause just before the amount.
          place = merchant_for(segment)
          if place.present?
            spoken_place = place
            spoken_date = context_date
            spoken_range = @segment_ranges[segment]
          end
          if place.present? && !segment.match?(DEAL_PATTERN)
            # The optional extractor may bind this price, but a legacy builder
            # must never turn an incomplete report into a single draft.
            if written_amounts(segment).any?
              return Result.new(status: :none, reason: { kind: :unbound_purchase, question: "How much was the #{place} purchase?" })
            end
            continuation = segment.match?(/\A(?:a|an|some|lunch|dinner|breakfast|coffee|groceries|gas|food|snacks?|sandwich|at|from)\b/i)
            unpriced << place if own_verb || continuation
          end
          next
        end
        merchant = amounts.length == 1 ? merchant_for(segment) : ""
        row_date = explicit_date || context_date
        source_text = @segment_sources.fetch(segment, segment)
        if merchant.blank? && amounts.length == 1 && spoken_place
          return result(:rejected) if explicit_date && spoken_date && explicit_date != spoken_date
          row_date = explicit_date || spoken_date || context_date
          range = @segment_ranges[segment]
          source_text = @original_message[spoken_range.begin...range.end].squish if spoken_range && range
          merchant, spoken_place = spoken_place, nil
          unpriced.delete(merchant)
        end
        amounts.each { |cents| rows << { amount_cents: cents, merchant: merchant, date: row_date, source_text: source_text } }
      end
      if unpriced.any?
        return Result.new(status: :rejected, reason: { question: "How much was the #{unpriced.first} purchase?" })
      end
      # A card payment or savings move alone is not an unread purchase.
      # Nothing priced was read: a card payment, savings move or deal alone is not
      # an unread purchase for the extractor to guess at.
      return skipped || @message.match?(DEAL_PATTERN) ? result(:excluded) : [] if rows.empty?
      return result(:rejected) if rows.length > MAX_PURCHASES

      @purchase_sources = rows.map { |row| row[:source_text] }
      purchases = assign_dates(rows)
      outside = purchases.find { |row| !open_day?(row[:purchased_on]) }
      return window_rejection(outside[:purchased_on]) if outside

      purchases
    end

    # A clause without its own day shares the nearest earlier one, else the
    # next one ("$8 at Shell and $20 at Payless yesterday"), else today.
    def assign_dates(rows)
      rows.each_with_index.map do |row, index|
        date = row[:date] || rows[0...index].reverse.find { |other| other[:date] }&.fetch(:date) ||
          rows[(index + 1)..].find { |other| other[:date] }&.fetch(:date) || date_reading || today
        { amount_cents: row[:amount_cents], merchant: row[:merchant], purchased_on: date }
      end
    end

    def open_day?(date) = date && date >= @enrollment.starts_on && date <= last_open_day

    # A real day that cannot be recorded, so Mia can say which and why.
    def window_rejection(date)
      kind = if date > today then :future elsif date < @enrollment.starts_on then :before_start else :after_end end
      Result.new(status: :rejected, reason: { kind: kind, date: date, starts_on: @enrollment.starts_on, ends_on: @enrollment.ends_on, today: today })
    end

    # "Shell $8", "$8.25 at Shell", "lunch 12.50 at Kings": one amount with a place, briefly.
    def list_form?(segment)
      text = mask(segment, date_tokens(segment)).gsub(/~+/, " ").gsub(/\b\d+\s+for\s+(?=\$)/i, "").squish
      return false if text.split.size > 8 || text.scan(/\d[\d,]*(?:\.\d+)?/).size != 1
      # "My car payment is $450" describes money; a list line names a place.
      return false if text.match?(/\A(?:i|we|my|our|his|her|their|kids?|children|people)\b|\b(?:is|are|was|were|be|been)\b/i)

      text.match?(LIST_ITEM) || text.match?(/(?:\A|\s)(?:at|from|@)\s+[a-z]/i)
    end

    def split_segments(text)
      @segment_sources = {}
      @segment_ranges = {}
      cursor = 0
      text.split(/\n+|;|(?<=[.!])\s+|,(?!\d{3}(?!\d))\s*|\s+(?:and|then|plus|also)\s+(?=\S)/i).filter_map do |part|
        start = text.index(part, cursor)
        cursor = start + part.length
        segment = part.squish.sub(/\A(?:(?:and|then|also|plus)\s+)+/i, "").sub(/[.!]+\z/, "")
        next if segment.blank?

        @segment_ranges[segment] = start...cursor
        @segment_sources[segment] = @original_message[start...cursor].squish
        segment
      end
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
        # "Coffee 4.75": dollars and cents on a short line is money even without "$".
        return [] unless list[:dollar] || verb || list_like || list[:amount].match?(/\.\d{2}\z/)
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
        # Deal wording ("2 for 1", "buy 2 for 1") is a quantity, not the price.
        next if before.match?(/\b\d+\s+for\s*\z/i)

        cents_written = match[1].match?(/\.\d{2}\z/)
        money = before.match?(BARE_AFTER_VERB) ||
          (before.match?(LEADING_JOINER) && (verb || after.match?(/\A[^$\d]*?\s(?:at|@|from)\s+[a-z]/i))) ||
          (before.match?(/\bfor\s*\z/i) && verb) ||
          (verb && before.match?(/\A\s*(?:(?:a|an|some)\s+)?(?:lunch|dinner|breakfast|coffee|groceries|gas|food|snacks?|sandwich)\s+\z/i) && after.match?(/\A\s+(?:at|@|from)\s+[a-z]/i)) ||
          # "lunch 12.50 at Kings": dollars and cents beside a place, or on a short line.
          (cents_written && (after.match?(/\A\s+(?:at|@|from)\s+[a-z]/i) || masked.split.size <= 4))
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
        back = (today.wday - index) % 7
        # "last Monday" said on a Monday is a week ago, not today.
        back = 7 if back.zero? && match[0].match?(/\Alast\s/i)
        return today - back
      end
      month = MONTHS.fetch(match[:month].downcase[0, 3])
      year = match[:year]&.to_i || today.year
      date = Date.new(year, month, match[:day].to_i)
      return date if match[:year] || date <= today
      # A month/day shortly ahead is a future day (rejected as such), not last year.
      date - today <= 31 ? date : Date.new(year - 1, month, match[:day].to_i)
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
