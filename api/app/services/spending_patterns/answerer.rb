module SpendingPatterns
  # Both household and challenge chats narrate observations from reviewed money,
  # never planned allocations. No financial writes are permitted on this path.
  class Answerer
    QUESTION = /\b(?:what|which|show|tell|help|see|notice|spot|find|look|analy[sz]e)\b/i.freeze
    PATTERN = /\b(?:spending|purchase|shopping)\s+(?:patterns?|habits?)\b|\bpatterns?\b.*\b(?:spending|purchases?|shopping)\b/i.freeze
    WRITE = /\b(?:set|change|update|move|create|add|delete|remove|apply|save|confirm|lower|raise|increase|decrease)\b/i.freeze
    # These double as nouns ("my spending log"), so only an object after them
    # makes them a request.
    ACTION_REQUEST = /\b(?:draft|prepare|log|record|transfer|cancel)\s+(?:a|an|the|my|our|this|that|these|those|it|them|me|\$|\d)/i.freeze
    # The subscriptions must be what she's asking about: "what subscriptions do we pay for?",
    # not "how are we doing after cancelling the gym membership?" or "a Costco membership?".
    # "What should we cut first?", "Where can I cut back on spending?": asking Mia to pick a cut. Not "What
    # if I cut dining out to cover it?" (a cut she already has in mind) or "where can we cut back weekend
    # shifts" (work, not spending).
    CUT_QUESTION = /\b(?:what|which|where)\b[^.?!]{0,25}\b(?:should|can|could|do)\s+(?:i|we)\s+(?:cut|trim)(?:\s+(?:back|down|first))?(?:\s+on\s+(?:my\s+|our\s+)?(?:spending|purchases|shopping|expenses))?\s*[?.!]*\z/i.freeze
    PROTECTED_NOTE = "Rent, bills, medical care and money for family aren’t on this list.".freeze
    SUBSCRIPTIONS_QUESTION = /\b(?:what|which|any|list|show|check|tell\s+me|how\s+many|how\s+much|too\s+many)\b[^.?!]{0,40}\b(?:subscriptions|memberships|subscription\s+(?:charges|services)|streaming\s+services|recurring\s+(?:charges|payments|bills))\b|\bwhich\s+subscription\b|\b(?:do|am|are)\s+(?:i|we)\s+(?:have|paying|pay(?:ing)?\s+for)\s+(?:any\s+|too\s+many\s+|an?\s+[\w+.]+\s+)?(?:subscriptions?|memberships|streaming\s+services)\b/i.freeze

    # Conservative read-only floor for an unavailable reader. The live reader
    # handles meaning; this only recognizes clear requests to observe spending.
    def self.observation_question?(message)
      return false if HouseholdFinance::MessageReplyIntent.purchase_question?(message) || HouseholdFinance::ParticipantCare.required?(message)
      return true if subscriptions_question?(message)
      # Income and "is our budget realistic?" have their own answers.
      return false if HouseholdFinance::MiaIncomeAnswer.topic?(message) || HouseholdFinance::MiaMonthAnswer.question?(message)
      return true if HouseholdFinance::MessageReplyIntent.matches?(message, "spending_patterns")
      return false if HouseholdFinance::MessageReplyIntent.known?(message)

      return true if WhereMoneyGoes.question?(message) || cut_question?(message)

      (message.match?(/\b(?:what(?:s|['’]s)?|which|show|tell|notice|spot|see|look|analy[sz]e)\b/i) && message.match?(PATTERN)) ||
        message.match?(/\b(?:notice|stands? out|unusual|weird)\b.{0,45}\b(?:spending|statement|purchases?)\b|\b(?:where|how)\b.{0,20}\b(?:cut back|trim spending)\b(?:[?.!]*\s*\z|.{0,25}\b(?:spending|purchases|shopping|groceries|takeout|budget)\b)|\bsmall (?:buys|purchases)\b.{0,20}\badd(?:ing)? up\b/i)
    end

    def self.subscriptions_question?(message) = message.to_s.match?(SUBSCRIPTIONS_QUESTION)
    def self.cut_question?(message) = message.to_s.match?(CUT_QUESTION)

    def self.matches?(message)
      current = HouseholdFinance::ParticipantMessageReader::Current
      return false if current.message.to_s.squish == message.to_s.squish && current.reading&.facts&.any?

      observation_question?(message) && !message.match?(WRITE) && !message.match?(ACTION_REQUEST) &&
        !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(message) &&
        !::Mia::CrisisBoundary.matches?(message) && !::Mia::CrisisBoundary.hopeless?(message) &&
        !HouseholdFinance::MoneyMovementText.food_insecurity?(message)
    end

    def self.partial_month_summary(patterns, today:)
      recorded = patterns[:coverage][:months].select { |row| row[:spending_cents] }
      return unless recorded.any? && recorded.all? { |row| row[:month] == today.strftime("%Y-%m") }

      count = patterns[:purchase_count]
      cents = patterns[:observed_spending_cents]
      amount = ActiveSupport::NumberHelper.number_to_currency(HouseholdFinance::Money.dollars(cents), precision: cents.modulo(100).zero? ? 0 : 2)
      stores = patterns[:merchants].first(2).pluck(:label).to_sentence
      "From purchases you’ve reviewed so far this month, I see #{count} #{'purchase'.pluralize(count)} totaling #{amount}, including #{stores}. This may not include everything you’ve spent. Review more purchases or a full statement before drawing a longer-term pattern."
    end

    def self.question_reference(message:, observed:, waterfall:, estimate:, question:)
      if message.match?(/\bsmall (?:buys|purchases)\b/i)
        return "#{waterfall.strip} #{observed} Which of those purchases would you want to look at together?" if waterfall.present?
        return "I don't see a cluster of small purchases in the reviewed records. #{observed}"
      end
      if message.match?(/\b(?:cut back|trim|reduce)\b/i)
        return "#{observed} A store total can include essentials, so let's look at what you bought before choosing a cut. Which purchase felt optional?"
      end
      return "#{observed}#{waterfall} Does anything there surprise you?" if message.match?(/\b(?:stands? out|statement)\b/i)

      "#{observed}#{waterfall}#{estimate} #{question}"
    end

    # Rails states what repeats; there is nothing for a narrator to round or rename.
    def self.subscriptions_reply(patterns)
      present = patterns[:coverage][:months].select { |row| row[:spending_cents] }.map { |row| Date.iso8601("#{row[:month]}-01").strftime("%b") }
      return "I don’t have reviewed purchases to check for subscriptions yet. You can review a statement or tell me about a few purchases to start." if present.empty?

      span = present.one? ? "In #{present.first}" : "From #{present.first} to #{present.last}"
      other_accounts = "A subscription paid from another card or account won’t show until that statement is reviewed."
      found = patterns[:possible_subscriptions]
      return "#{span}, I don’t see a charge in your reviewed purchases that repeats every month at a steady price. #{other_accounts}" if found.empty?

      list = found.map { |row| "#{row[:merchant]} (#{money(row[:latest_amount_cents])})" }
      together = found.one? ? "" : " Together that’s about #{money(found.sum { |row| row[:latest_amount_cents] })} a month."
      "#{span}, #{found.one? ? 'this repeats' : 'these repeat'} about monthly at a steady price, so #{found.one? ? 'it looks like a subscription' : 'they look like subscriptions'}: #{list.to_sentence}.#{together} #{other_accounts} Is there one you don’t use anymore?"
    end

    # Stores she keeps going back to, so a one-off payment is never named beside a cut. With only one
    # month recorded every store is new, so name the biggest; no cut is offered for them.
    def self.flexible_stops(patterns) = (patterns[:recurring_discretionary_merchants].presence || patterns[:discretionary_merchants]).first(2)

    def self.money(cents) = ActiveSupport::NumberHelper.number_to_currency(HouseholdFinance::Money.dollars(cents), precision: cents % 100 == 0 ? 0 : 2)

    def initialize(household:, message:, persona:, history:, approved_content:, available_product_modules: nil)
      @household, @message, @persona, @history, @approved_content = household, message, persona, history, approved_content
      @available_product_modules = available_product_modules
    end

    attr_reader :supplied_content_context, :patterns

    def call
      @supplied_content_context = []
      return subscriptions_answer if self.class.subscriptions_question?(@message)
      period = RequestedPeriod.new(WhereMoneyGoes.question?(@message) ? WhereMoneyGoes.period_text(@message) : @message).call
      @patterns = Analyzer.new(@household, **period).call
      if period.present? && @patterns[:purchase_count].zero?
        label = "#{period[:from].strftime('%B %-d, %Y')} through #{period[:to].strftime('%B %-d, %Y')}"
        return "I don’t have reviewed purchases for #{label}, so I can’t tell what you spent then. You can review a statement or tell me about purchases from that period."
      end
      if period.present?
        period_label = period[:from].strftime("%B %Y")
        period_label = "#{period[:from].strftime('%B %-d, %Y')} through #{period[:to].strftime('%B %-d, %Y')}" unless period[:from] == period[:from].beginning_of_month && period[:to] == period[:from].end_of_month
      end
      return WhereMoneyGoes.new(@household, @patterns, period_label: period_label).call if WhereMoneyGoes.question?(@message)
      partial = self.class.partial_month_summary(@patterns, today: Time.current.in_time_zone("Pacific/Guam").to_date) if period.empty?
      return partial if partial
      choices = @patterns[:candidate_changes].first(2)
      coverage = @patterns[:coverage]
      present = coverage[:months].select { |row| row[:spending_cents] }.map { |row| Date.iso8601("#{row[:month]}-01").strftime("%b") }
      missing = coverage[:months].any? { |row| row[:spending_cents].nil? }
      merchants = self.class.flexible_stops(@patterns)
      if merchants.empty?
        return "I don’t have enough reviewed purchases in flexible categories to spot a pattern yet. You can review a statement or tell me about a few purchases to start. A store name alone doesn’t tell me what you needed."
      end
      window = if period.present?
        "For #{period_label}#{missing ? ", I only see purchases for #{present.to_sentence}:" : ' in the recorded purchases,'}"
      else
        missing ? "I only see purchases for #{present.to_sentence}:" : "From #{present.first} to #{present.last} in the recorded purchases,"
      end
      flexible = merchants.map { |row| "#{row[:label]} (#{money(row[:total_cents])})" }
      category_names = @patterns[:discretionary_categories].first(2).pluck(:label).reject { |name| name.casecmp?("Flexible spending") }
      observed = "#{window} #{flexible.to_sentence} #{flexible.one? ? 'was your biggest flexible spending stop' : 'were your biggest flexible spending stops'}."
      observed = "#{observed} Your largest flexible spending #{category_names.one? ? 'category was' : 'categories were'} #{category_names.to_sentence}." if category_names.any?
      observed = "#{observed} #{PROTECTED_NOTE}" if self.class.cut_question?(@message)
      cluster = @patterns[:small_purchase_clusters].first
      waterfall = cluster ? " #{cluster[:purchase_count]} small buys of #{money(cluster[:threshold_cents])} or less stacked up around #{cluster[:label]} — #{money(cluster[:total_cents])} altogether." : ""
      impact = choices.first
      estimate = impact ? " Spending half as much at #{impact[:merchant]} could free about #{money(impact[:monthly_impact_cents])} a month, based on the months recorded." : ""
      question = if choices.empty?
        "Would you feel comfortable looking at one of these purchases together?"
      else
        "Would you feel more comfortable cutting back on #{choices.map { |choice| choice[:merchant] }.join(' or ')}?"
      end
      narrator = Narrator.new(user_message: @message, persona: @persona, history: @history, approved_content: @approved_content,
        answer_packet: { kind: "household_patterns", write_state: "no_write", fallback_response: pattern_reference(observed, waterfall, estimate, question),
          available_product_modules: @available_product_modules,
          verified_facts: { merchants: merchants, category_names: category_names, cluster: cluster, choices: choices, months_with_purchases: present, missing_months: missing } })
      answer = narrator.call
      @supplied_content_context = narrator.supplied_content_context
      period.present? && @patterns[:observed_spending_cents] ? "Your reviewed purchases for this period total #{money(@patterns[:observed_spending_cents])}. #{answer}" : answer
    rescue RequestedPeriod::Unsupported
      "I couldn’t identify a supported spending period. Try a month and year, like January 2025, or the last 3 months (up to 12). Nothing changed."
    end

    private

    def subscriptions_answer
      # "every month" is how subscriptions are paid, not a period to read. A named
      # period still counts, but one month can't show a repeat, so look back at least three.
      period = begin
        RequestedPeriod.new(@message).call
      rescue RequestedPeriod::Unsupported
        {}
      end
      period = period.merge(from: [ period[:from], period[:to].beginning_of_month - 2.months ].min) if period.present?
      @patterns = Analyzer.new(@household, **period).call
      self.class.subscriptions_reply(@patterns)
    end

    def pattern_reference(observed, waterfall, estimate, question)
      self.class.question_reference(message: @message, observed: observed, waterfall: waterfall, estimate: estimate, question: question)
    end

    def money(cents) = self.class.money(cents)
  end
end
