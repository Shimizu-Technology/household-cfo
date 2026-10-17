require "json"

module Mia
  # The scripted reply Mia gives when she has no checked model answer to return.
  #
  # It never repeats the participant's message. It says plainly why the full
  # answer is missing (the model could not be reached, or its answer could not
  # be checked against approved numbers) and adds the approved fact that fits the
  # question, read from the same household context the model was given. A short
  # correct answer is better than a wrong number, so nothing here is calculated:
  # every amount is copied from an approved metric.
  class FallbackReply
    REASONS = %i[provider_unavailable reply_rejected no_model].freeze

    TOPIC_PATTERNS = {
      readiness: /\b(?:readiness|colou?r|on track|how (?:are|r) (?:we|you|i) doing|how (?:we|i)(?:['’]re| are)? doing|how(?:['’]s| is) (?:it|everything) looking)\b/i,
      debt: /\b(?:owe[sd]?|debts?|credit cards?|loans?|paid off|pay(?:ing)? (?:it |this |that |them |the card |the loan )?off|payoff|minimum payments?)\b/i,
      safe_to_spend: /\b(?:safe[- ]to[- ]spend|afford)\b/i,
      income: /\b(?:income|paychecks?|take[- ]home|salary|wages?)\b/i,
      savings: /\b(?:savings?|runway|emergency fund)\b/i
    }.freeze

    PROVIDER_UNAVAILABLE = "I can’t give you a full answer right now because I’m having trouble reaching my coaching service. Please try again in a few minutes.".freeze
    NOTHING_CHANGED = "Nothing in your household records changed.".freeze
    CHECKED_BASIS = "That comes from your approved household numbers, and I left out anything I could not check against them.".freeze
    ASK_INSTEAD = "Ask me about your readiness, safe-to-spend, debt, or this month’s spending, and I’ll answer from your saved records.".freeze
    NO_FACTS = "I would rather say that plainly than guess.".freeze
    HOPELESS_OPENING = "That sounds really heavy, and you do not have to fix all of it tonight.".freeze
    HOPELESS_DEBT_STEP = "One next step for this week: keep the minimum payments current, and tell me which bill feels heaviest so we can look at it together.".freeze
    HOPELESS_STEP = "One next step for this week: tell me which bill feels heaviest, and we will look at it together.".freeze
    HOPELESS_CHALLENGE_STEP = "One small step for this week: set aside any amount that feels doable, even a small one, or tell me what feels hardest about saving and we will look at it together. A smaller or later target is always okay.".freeze
    NEXT_MOVES = {
      readiness: "Ask me what is holding readiness back, and I’ll walk through runway and surplus with you.",
      debt: "Keep every minimum payment current, and ask me to compare payoff options when you are ready.",
      safe_to_spend: "Check any new purchase against that guardrail before money leaves the household.",
      income: "If that number is out of date, update it in My Money so I coach from the right picture.",
      savings: "Ask me how to grow your runway, and I’ll work from these numbers."
    }.freeze
    NO_DEBT_NEXT_MOVE = "If a balance or payment is missing, add it in My Money so I coach from the right picture.".freeze
    READINESS_UNAVAILABLE = {
      "unavailable_until_debt_minimums_confirmed" => "I can’t give a readiness color yet because your monthly debt minimums are not confirmed; add them, or a $0 debt summary if nothing is owed.",
      "unavailable_until_liquid_balances_confirmed" => "I can’t give a readiness color yet because your account balances are not entered.",
      "unavailable_until_setup_complete" => "I can’t give a readiness color yet because your setup essentials are not finished."
    }.freeze

    def self.topic_for(message)
      matched = TOPIC_PATTERNS.select { |_topic, pattern| message.to_s.match?(pattern) }.keys
      matched.one? ? matched.first : :general
    end

    def initialize(reason:, message:, context:, persona:, hopeless: false, purchase_question: false)
      @reason = REASONS.include?(reason) ? reason : :reply_rejected
      @topic = purchase_question ? :safe_to_spend : self.class.topic_for(message)
      @payload = parse(context)
      @persona = persona
      @hopeless = hopeless
    end

    def call
      return hopeless_reply if @hopeless
      return provider_unavailable_reply if @reason == :provider_unavailable

      direct = topic_fact
      return [ direct, CHECKED_BASIS, next_move ].join(" ") if direct

      [ @persona.uncertainty_line, general_fact || NO_FACTS, ASK_INSTEAD ].join(" ")
    end

    private

    def provider_unavailable_reply
      [ PROVIDER_UNAVAILABLE, topic_fact || general_fact, NOTHING_CHANGED ].compact.join(" ")
    end

    # The wellbeing check (988) is added where every reply is saved; this keeps
    # the money help itself short and kind so the whole reply stays readable.
    # Minimum payments come up only when a positive debt balance is saved.
    def hopeless_reply
      owes = debt_owed?
      # In the savings challenge a full budget is optional: skip the setup
      # status and give a challenge-sized next step.
      return [ HOPELESS_OPENING, owes ? debt_fact : nil, owes ? HOPELESS_DEBT_STEP : HOPELESS_CHALLENGE_STEP ].compact.join(" ") if challenge?

      [ HOPELESS_OPENING, owes ? debt_fact : general_fact, owes ? HOPELESS_DEBT_STEP : HOPELESS_STEP ].compact.join(" ")
    end

    # Minimum-payment advice only when a positive debt balance is saved.
    def next_move
      return NO_DEBT_NEXT_MOVE if @topic == :debt && !debt_owed?

      NEXT_MOVES.fetch(@topic)
    end

    def topic_fact
      case @topic
      when :readiness then readiness_fact
      when :debt then debt_fact
      when :safe_to_spend then safe_to_spend_fact
      when :income then income_fact
      when :savings then savings_fact
      end
    end

    def general_fact
      color, meaning = readiness_parts
      return READINESS_UNAVAILABLE[metric("readiness")] unless color

      readiness = meaning ? "#{color} (#{meaning})" : color
      surplus = metric("baseline_surplus")
      "What I can tell you is that your readiness is #{readiness}#{" and your baseline surplus is #{surplus} a month" if surplus}."
    end

    def readiness_fact
      color, meaning = readiness_parts
      return READINESS_UNAVAILABLE[metric("readiness")] unless color

      runway = runway_months
      sentence = meaning ? "Your readiness is #{color}: #{meaning}." : "Your readiness is #{color}."
      runway ? "#{sentence.delete_suffix('.')}, with #{runway} months of runway." : sentence
    end

    def challenge?
      @payload.dig("program", "experience_mode") == "savings_challenge"
    end

    def debt_total
      metric("total_debt_entered") || @payload.dig("debts", "canonical_total_balance").presence
    end

    def debt_fact
      total = debt_total
      return unless total

      minimum = @payload.dig("debts", "canonical_monthly_minimum").presence if debt_owed?
      minimum ? "Your saved debt total is #{total}, with #{minimum} a month in minimum payments." : "Your saved debt total is #{total}."
    end

    def debt_owed?
      HouseholdFinance::Money.chat_cents(debt_total.to_s.delete("$")).to_i.positive?
    rescue ArgumentError
      false
    end

    def safe_to_spend_fact
      amount = metric("safe_to_spend")
      return "Your safe-to-spend this month is #{amount}, which is a decision guardrail, not an account balance." if amount

      READINESS_UNAVAILABLE[metric("readiness")]
    end

    def income_fact
      amount = metric("monthly_income")
      "Your approved monthly income is #{amount}." if amount
    end

    def savings_fact
      liquid = metric("liquid_assets")
      return unless liquid

      runway = runway_months
      runway ? "Your saved liquid accounts total #{liquid}, which is #{runway} months of runway." : "Your saved liquid accounts total #{liquid}."
    end

    def readiness_parts
      label = metric("readiness")
      color = label.to_s[/\A\s*(red|yellow|green)\b/i, 1]
      return [ nil, nil ] unless color

      meaning = label.to_s.sub(/\A\s*#{color}\s*[—–:,-]*\s*/i, "").strip.presence
      [ color.capitalize, meaning ]
    end

    def runway_months
      value = Float(@payload.dig("metrics", "runway_months"), exception: false)
      return unless value&.finite?

      format("%.1f", value).delete_suffix(".0")
    end

    def metric(key)
      value = @payload.dig("metrics", key)
      value.is_a?(String) ? value.strip.presence : nil
    end

    def parse(context)
      parsed = context.is_a?(String) ? JSON.parse(context) : context.to_h
      parsed.is_a?(Hash) ? parsed.deep_stringify_keys : {}
    rescue JSON::ParserError, TypeError, NoMethodError
      {}
    end
  end
end
