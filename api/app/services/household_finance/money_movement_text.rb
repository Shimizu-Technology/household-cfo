module HouseholdFinance
  # Money a participant moves into savings or an investment is not spending, and a
  # family short on food needs help before any budget answer. These checks read
  # participant chat text only; they never write records.
  module MoneyMovementText
    AMOUNT_SOURCE = "\\$?\\s*(#{Money::CHAT_NUMBER_SOURCE}(?![\\d,])#{Money::CHAT_THOUSANDS_SOURCE}?)(?:\\s+(?:dollars?|bucks))?".freeze
    SAVINGS_WORD_SOURCE = "(?:sav(?:ings?|ins|ngs|igs)|challenge|emergency\\s+fund|rainy[- ]day\\s+fund)".freeze
    # "my savings", "Bank of Guam savings", "my challenge account"; never "from savings"
    # or "to checking from savings", and never a store or loan named "Savings".
    SAVINGS_DESTINATION_SOURCE = "(?:in|into|inside|to|toward|towards|onto)\\s+" \
      "(?:(?:my|our|the|da|a|his|her|their|kids?['’]?|family)\\s+)?(?:bank\\s+of\\s+guam\\s+|bog\\s+)?" \
      "(?:(?!(?:from|out|of|and|then|pay|for|with|on|at|in|to|into)\\b)[a-z0-9'’-]+\\s+){0,2}?" \
      "#{SAVINGS_WORD_SOURCE}\\b(?!\\s+(?:mart|market|store|shop|outlet|cent(?:er|re)|bond|loan|card|fee|entry)\\b)".freeze
    SAVINGS_DEPOSIT_VERB_SOURCE = "(?:put|paid|payed|transferred|transfered|moved|deposited|added|sent|stashed|dropped|saved|tucked)".freeze
    SAVINGS_DEPOSIT_PATTERN = Regexp.new(
      "\\b#{SAVINGS_DEPOSIT_VERB_SOURCE}\\s+(?:(?:in|another|an\\s+extra|extra)\\s+)?#{AMOUNT_SOURCE}" \
      "(?:\\s+(?:cash|more|extra|aside|away|over|back|today|yesterday|already))*" \
      "(?:\\s+from\\s+(?:my\\s+|our\\s+|the\\s+)?(?:checking|paycheck|pay\\s*check|pay|check|wallet|cash)(?:\\s+account)?)?" \
      "\\s+#{SAVINGS_DESTINATION_SOURCE}" \
      "|\\b#{SAVINGS_DEPOSIT_VERB_SOURCE}\\s+(?:it\\s+|that\\s+)?#{SAVINGS_DESTINATION_SOURCE}\\s+(?:account\\s+)?#{AMOUNT_SOURCE}" \
      "|\\b(?:set|put)\\s+(?:aside\\s+)?#{AMOUNT_SOURCE}(?:\\s+aside)?\\s+for\\s+(?:my\\s+|our\\s+|the\\s+)?(?:savings|challenge)\\b(?!\\s+(?:fee|entry|shirt|t-shirt))",
      Regexp::IGNORECASE
    ).freeze
    SAVINGS_DEPOSIT_EXCLUSION_PATTERN = /\b(?:fees?|penalty|overdraft|withdr(?:aw|ew|awn|awal)|(?:took|pulled)\s+(?:(?:it|that|some|\$?\d[\d,.]*k?)\s+)?(?:back\s+)?out|cash(?:ed)?\s+out|out\s+of\s+(?:my\s+|our\s+|the\s+)?savings)\b/i.freeze

    INVESTMENT_ASSET_SOURCE = "(?:bitcoin|btc|crypto(?:currency|currencies|s)?|ethereum|eth|dogecoin|doge|meme\\s*coins?|nfts?|stocks|" \
      "stock\\s+market|shares\\s+of|etfs?|index\\s+funds?|mutual\\s+funds?|" \
      "robinhood|coinbase|webull|crypto\\.com)\\b".freeze
    INVESTMENT_PURCHASE_VERB_SOURCE = "(?:bought|buy|purchased|spent|put|invested|paid|moved|transferred|sent|threw|dropped|got)".freeze
    INVESTMENT_PURCHASE_PATTERN = Regexp.new(
      "\\b#{INVESTMENT_PURCHASE_VERB_SOURCE}\\s+(?:about\\s+|around\\s+|like\\s+|another\\s+)?#{AMOUNT_SOURCE}" \
      "(?:\\s+worth)?(?:\\s+(?:of|in|into|on|for|to|toward|towards|at|with|from))?(?:\\s+(?:some|more|my|our|the|a|an|new))*\\s+#{INVESTMENT_ASSET_SOURCE}" \
      "|\\b#{INVESTMENT_PURCHASE_VERB_SOURCE}\\s+(?:some\\s+|more\\s+|a\\s+little\\s+)?#{INVESTMENT_ASSET_SOURCE}[^.!?;,]{0,25}?\\$\\s*\\d",
      Regexp::IGNORECASE
    ).freeze
    INVESTMENT_MERCHANT_PATTERN = Regexp.new("\\A\\s*(?:the\\s+)?#{INVESTMENT_ASSET_SOURCE}", Regexp::IGNORECASE).freeze

    # Words before the verb that make it a plan, a question, or something that did not happen.
    NOT_DONE_PREFIX_PATTERN = /\A\s*(?:how|what|why|which|did|do|does|is|are|was|were|have|has)\b|\b(?:will|gonna|going\s+to|plan(?:ning)?\s+to|want(?:ed)?\s+to|wanna|should|could|would|might|may|can|if|when|whenever|once|remind|need(?:ed)?\s+to|have\s+to|has\s+to|try(?:ing)?\s+to|hope\s+to|tomorrow|next|didn['’]?t|did\s+not|don['’]?t|do\s+not|haven['’]?t|have\s+not|never|not|couldn['’]?t|can['’]?t|cannot|forgot\s+to|supposed\s+to)\b/i.freeze

    FOOD_SOURCE = "(?:food|groceries|grocery|grocerys|meals?|breakfast|lunch|dinner)".freeze
    # Eating out, takeout, food trucks and grocery budgets are spending choices, not hunger.
    DISCRETIONARY_FOOD_PATTERN = /\b(?:switch(?:ed|ing)?\s+to|cheaper|store\s+brand|on\s+sale|coupons?|in\s+bulk|eat(?:ing)?\s+out|dine|dining\s+out|take\s*out|delivery|door\s*dash|restaurants?|fast\s+food|food\s+trucks?|food\s+court|starbucks|mcdonald['’]?s|jollibee|coffee|snacks?)\b/i.freeze
    FOOD_BUDGET_PATTERN = /\b(?:food|grocery|groceries)\s+(?:budget|category|allocation|plan|line)\b/i.freeze
    NOT_HARDSHIP_PATTERN = /\b(?:not\s+hungry|picky|(?:doesn|don|didn)['’]?t\s+like|diet(?:ing)?|fasting|lent|ramadan|food\s+allerg\w*|what\s+if|in\s+case|suppose|hypothetical(?:ly)?|used\s+to|last\s+year|years?\s+ago|back\s+(?:then|when)|growing\s+up|running\s+late|overslept|in\s+a\s+rush|lose\s+weight|fiesta|part(?:y|ies)|birthday|potluck|bbq|barbecue|catering|rosary|novena|wedding|funeral|graduation)\b/i.freeze
    HARDSHIP_REASON_SOURCE = "(?:no\\s+(?:more\\s+)?(?:money|cash|food|groceries)|(?:can['’]?t|cant|cannot|can\\s+not|could(?:n['’]?t|\\s+not))\\s+afford|broke|" \
      "out\\s+of\\s+(?:money|food|cash|groceries)|nothing\\s+(?:left\\s+)?to\\s+eat|short\\s+on\\s+(?:money|cash)|" \
      "(?:have|got|has)\\s+nothing|(?:until|til|till|before)\\s+(?:payday|pay\\s+day|we\\s+get\\s+paid|i\\s+get\\s+paid|(?:my|our|the|next)\\s+(?:pay)?check))".freeze
    MONEY_REASON_SOURCE = "(?:no\\s+(?:more\\s+)?(?:money|cash)|(?:can['’]?t|cant|cannot|can\\s+not|could(?:n['’]?t|\\s+not))\\s+afford|broke|out\\s+of\\s+(?:money|cash)|" \
      "short\\s+on\\s+(?:money|cash)|(?:until|til|till|before)\\s+(?:payday|pay\\s+day|we\\s+get\\s+paid|i\\s+get\\s+paid|(?:my|our|the|next)\\s+(?:pay)?check))".freeze
    STRONG_FOOD_INSECURITY_PATTERNS = [
      /\bnothing\s+(?:left\s+)?(?:to|fo)\s+eat\b(?!\s+(?:at|in)\s+(?:work|school|the\s+office))/i,
      /\b(?:have|got|has|there\s+is|there['’]?s)\s+(?:no|zero)\s+(?:more\s+)?(?:food|groceries)\b(?!\s+(?:deliver|truck|court|allerg|stamps))/i,
      /\bno\s+(?:more\s+)?(?:food|groceries)\s+(?:in\s+the\s+(?:house|fridge)|at\s+home|left|until|till|til)\b/i,
      /\b(?:ran|run|running)\s+out\s+of\s+(?:food|groceries)\b(?!\s+(?:budget|category|allocation|money))|\b(?:are|am|we['’]?re|i['’]?m)\s+(?:completely\s+|totally\s+)?out\s+of\s+food\b(?!\s+(?:budget|category|allocation|money))/i,
      /\bwe\s+no\s+more\s+(?:food|money\s+for\s+(?:food|groceries))\b/i,
      /\b(?:kids?|children|child|baby|babies|son|daughter|keiki|grandkids?)\b[^.!?]{0,25}\b(?:skip(?:ping|ped|s)?|go(?:ing)?\s+without|went\s+without|miss(?:ing|ed)?)\s+(?:(?:their|our|my|a|some|the)\s+)?(?:meals?|food|breakfast|lunch|dinner|eating)\b(?!\s+out\b)/i,
      /\b(?:snap|ebt|food\s+stamps|wic)\b[^.!?]{0,20}\b(?:ran\s+out|run\s+out|is\s+out|is\s+gone|ran\s+low|is\s+low)\b/i
    ].freeze
    HARDSHIP_FOOD_PATTERNS = [
      Regexp.new("(?=.*\\b(?:out|low)\\s+(?:of|on)\\s+(?:food|groceries)\\b)(?=.*#{MONEY_REASON_SOURCE})", Regexp::IGNORECASE),
      Regexp.new("(?:can['’]?t|cant|cannot|can\\s+not|could(?:n['’]?t|\\s+not))\\s+afford\\s+(?:any\\s+|enough\\s+|our\\s+|my\\s+|the\\s+)?(?:food|groceries|grocery|grocerys|meals?|to\\s+(?:eat|feed|buy\\s+(?:food|groceries)))\\b", Regexp::IGNORECASE),
      Regexp.new("\\bno\\s+(?:more\\s+)?(?:money|cash)\\s+(?:left\\s+)?(?:for|to\\s+buy)\\s+(?:any\\s+)?#{FOOD_SOURCE}\\b", Regexp::IGNORECASE),
      Regexp.new("\\bnot\\s+enough\\s+(?:money\\s+)?(?:for|to\\s+buy)\\s+(?:any\\s+)?#{FOOD_SOURCE}\\b|\\bnot\\s+enough\\s+food\\b", Regexp::IGNORECASE),
      Regexp.new("\\bhungry\\b[^.!?]{0,60}\\b#{HARDSHIP_REASON_SOURCE}|#{HARDSHIP_REASON_SOURCE}[^.!?]{0,60}\\bhungry\\b", Regexp::IGNORECASE),
      Regexp.new("\\b(?:i|we|us)\\b[^.!?]{0,25}\\b(?:skip(?:ping|ped|s)?|go(?:ing)?\\s+without|went\\s+without)\\s+(?:(?:our|my|a|some|the)\\s+)?(?:#{FOOD_SOURCE}|eating)\\b[^.!?]{0,40}\\b(?:because|cause|cuz|since|as)\\b[^.!?]{0,20}#{HARDSHIP_REASON_SOURCE}", Regexp::IGNORECASE)
    ].freeze
    # "My friend can't afford groceries, can I lend her $50?" is family support, not
    # this household going without, unless the participant names their own hardship too.
    THIRD_PARTY_PATTERN = /\b(?:friend|cousin|neighbou?r|auntie|aunty|uncle|brother|sister|sibling|mom|mother|dad|father|parents?|in-laws?|co-?worker|grandma|grandpa|nana|tata|she|he|they)\b/i.freeze
    OWN_HARDSHIP_PATTERN = Regexp.new("\\b(?:i|we|us|our|my\\s+(?:kids?|children|son|daughter|baby|family))\\b[^.!?]{0,30}(?:#{HARDSHIP_REASON_SOURCE}|hungry|skip)", Regexp::IGNORECASE).freeze

    module_function

    def savings_deposit?(text)
      value = text.to_s.squish
      value.match?(SAVINGS_DEPOSIT_PATTERN) && !value.match?(SAVINGS_DEPOSIT_EXCLUSION_PATTERN)
    end

    # A completed deposit stated as a fact, not a plan, a question, or a lookup.
    def savings_deposit_report?(text)
      return false unless savings_deposit?(text)

      done_statement?(text, SAVINGS_DEPOSIT_PATTERN)
    end

    def savings_deposit_cents(text)
      match = text.to_s.squish.match(SAVINGS_DEPOSIT_PATTERN)
      token = match&.captures&.compact&.first
      cents = Money.chat_cents(token) if token
      cents if cents&.positive?
    end

    def investment_purchase?(text)
      text.to_s.squish.match?(INVESTMENT_PURCHASE_PATTERN)
    end

    def investment_purchase_report?(text)
      investment_purchase?(text) && done_statement?(text, INVESTMENT_PURCHASE_PATTERN)
    end

    def investment_merchant?(value)
      value.to_s.match?(INVESTMENT_MERCHANT_PATTERN)
    end

    # Savings deposits and investment buys move money; they are not expenses.
    def non_expense?(text)
      savings_deposit?(text) || investment_purchase?(text)
    end

    def food_insecurity?(text)
      value = text.to_s.squish
      return false if value.match?(NOT_HARDSHIP_PATTERN)
      return true if STRONG_FOOD_INSECURITY_PATTERNS.any? { |pattern| value.match?(pattern) }
      return false if value.match?(DISCRETIONARY_FOOD_PATTERN) || value.match?(FOOD_BUDGET_PATTERN)
      return false if value.match?(THIRD_PARTY_PATTERN) && !value.match?(OWN_HARDSHIP_PATTERN)

      HARDSHIP_FOOD_PATTERNS.any? { |pattern| value.match?(pattern) }
    end

    def done_statement?(text, pattern)
      value = text.to_s.squish
      value.split(/(?<=[.!?;])\s+|\n+/).any? do |sentence|
        match = sentence.match(pattern)
        next false unless match
        next false if sentence.include?("?")

        !sentence[0...match.begin(0)].to_s.match?(NOT_DONE_PREFIX_PATTERN)
      end
    end
  end
end
