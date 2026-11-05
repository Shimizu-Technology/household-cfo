module SavingsChallenge
  # The challenge's conversation boundary. Numbers are computed here; the
  # narrator coaches from verified facts; proposals still need review.
  class ChatTurn
    PATTERNS = /\b(?:patterns?|waterfall|subscriptions?)\b/i.freeze
    GOAL = /\b(?:goal|target)\b/i.freeze
    GOAL_CHANGE = /\b(?:change|set|make|update|lower|raise|switch|drop|bump|aim|let['’]?s do|go with)\b.{0,50}\b(?:goal|target)\b/i.freeze
    GOAL_DESIRE = /\b(?:(?:my|the)\s+(?:(?:challenge|savings)\s+)?(?:goal|target)\s+to be|i\s+(?:want|would like)\s+to save|i['’]d like to save)\b/i.freeze
    GOAL_STATEMENT = /\b(?:my|the)\s+(?:(?:challenge|savings)\s+)?(?:goal|target)\s+is\b/i.freeze
    WEEKLY_OFFER = /\b(?:i can(?: only)? (?:do|save|set aside)|i (?:want|would like) to save)\b/i.freeze
    AMOUNT_SOURCE = "#{HouseholdFinance::Money::CHAT_NUMBER_SOURCE}#{HouseholdFinance::Money::CHAT_THOUSANDS_SOURCE}?".freeze
    # A final sentence period is allowed; a third decimal digit is not.
    AMOUNT_END = /(?!\d|,\d|\.\d)/.source.freeze
    BARE_AMOUNT = /\A\s*\$?\s*(#{AMOUNT_SOURCE})\s*[.!]?\s*\z/.freeze
    # "Make it $400" names no goal, so it only counts inside an ongoing goal or
    # patterns conversation; elsewhere it is a correction to something else.
    STANDALONE_AMOUNT = /\A\s*(?:ok(?:ay)?,?\s+)?(?:make it|let['’]?s (?:do|go with|make it)|go with)\s+\$?\s*\d[\d,]*(?:\.\d{1,2})?(?:\s+instead(?:\s+of\s+\$?\s*\d[\d,]*(?:\.\d{1,2})?)?)?\s*(?:for (?:my|the) (?:goal|target))?\s*[.!]?\s*\z/i.freeze
    GOAL_TOPICS = %w[challenge_goal challenge_patterns].freeze
    PROGRESS = /\b(?:how am i doing|where am i|day\s*(?:30|60|90)|30\s*[\/,]\s*60|checkpoints?)\b/i.freeze

    def self.special?(message, session:)
      return false if protected_message?(message) || HouseholdFinance::MiaCoachAnswerer.prompt_injection?(message) || message.match?(/\bhousehold\b/i) || money_report?(message)
      message.match?(PATTERNS) || message.match?(GOAL_CHANGE) || message.match?(GOAL_DESIRE) || message.match?(GOAL_STATEMENT) || weekly_offer?(message) || message.match?(PROGRESS) ||
        amount_reply?(message, session: session) ||
        (message.match?(GOAL) && message.match?(/\b(?:comfortable|suggest|choose|pick|help|recommend)\b/i)) ||
        (session.active_topic["type"] == "challenge_patterns" && pattern_continuation?(message, choices: session.active_topic["choices"]))
    end

    # An ongoing goal or patterns conversation, or a goal card still waiting
    # for the participant's answer in this chat.
    def self.goal_conversation?(session)
      # A household-plan thread owns its own corrections ("make it $30").
      return false if session.active_topic.to_h["record_scope"] == "household_plan"

      session.active_topic["type"].in?(GOAL_TOPICS) ||
        SavingsChatCard.joins(:chat_message).where(chat_messages: { chat_session_id: session.id }, kind: "goal", status: "pending").exists?
    end

    def self.amount_reply?(message, session:)
      return false unless goal_conversation?(session)
      message = GoalAmount.normalize(message).sub(/\A\s*actually[, ]*/i, "").sub(/\blet['’]?s just\b/i, "lets")
      message.match?(STANDALONE_AMOUNT) || (message.match?(BARE_AMOUNT) &&
        (session.active_topic["type"] == "challenge_goal" ||
          SavingsChatCard.joins(:chat_message).where(chat_messages: { chat_session_id: session.id }, kind: "goal", status: "pending").exists?))
    end

    def self.weekly_offer?(message)
      message.match?(GoalAmount::WEEKLY) && message.match?(WEEKLY_OFFER)
    end

    def self.money_report?(message)
      return false if weekly_offer?(message)
      return false if message.match?(/\?|\A\s*(?:how|why|what|where|can|could|should|do|did|is|are)\b/i)
      message.match?(/\b(?:spent|bought|paid|saved|withdrew|set aside|no spending|no-spend)\b/i)
    end

    def self.protected_message?(message)
      message.match?(CoachAnswerer::PROTECTED_BASELINE) ||
        HouseholdFinance::MoneyMovementText.food_insecurity?(message) ||
        ::Mia::CrisisBoundary.matches?(message) || ::Mia::CrisisBoundary.hopeless?(message)
    end

    def self.pattern_continuation?(message, choices: [])
      return false if protected_message?(message)
      normalized = message.downcase.squish.sub(/[.!]\z/, "")
      return true if Array(choices).any? do |choice|
        merchant = Regexp.escape(choice["merchant"].to_s.downcase)
        merchant.present? && normalized.match?(/\A(?:(?:the one at|the|go with|let['’]?s do|cut back on|less at|i(?:['’]ll| will) (?:do|take|pick|choose|cut back on))\s+)?#{merchant}(?:\s+(?:one|please|then))?\z/)
      end
      return false if message.match?(/\b(?:spent|bought|paid|saved|withdrew|set aside|budget|category|income|salary|paycheck|account|asset|balance)\b/i)
      message.match?(/\b(?:first|second|choose|cut back|try|comfortable|say(?:ing)? no|reduce|rather|what (?:do|should)|options?)\b/i)
    end

    def self.replay_payload(payload, session:)
      id = payload.dig("challenge_chat_card", "id")
      return payload unless id
      card = SavingsChatCard.joins(:chat_message).where(chat_messages: { chat_session_id: session.id }).find_by(id: id)
      payload.merge("challenge_chat_card" => card&.as_api_json)
    end

    def initialize(household:, user:, enrollment:, session:, message:, attachments: [], persona:, history:, approved_content: [], available_product_modules: nil)
      @household, @user, @enrollment, @session, @message, @attachments = household, user, enrollment, session, message.to_s, attachments
      @persona, @history, @approved_content = persona, history, approved_content
      @available_product_modules = available_product_modules
      @topic = {}
    end

    attr_reader :answer, :intake, :supplied_content_context, :patterns

    def call
      @supplied_content_context = []
      if @enrollment && @attachments.empty? && !self.class.money_report?(@message) && !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message) && !self.class.protected_message?(@message)
        return self if review_continuation || pattern_turn || goal_turn || progress_turn
      end
      correction = SavingsCorrection.new(@enrollment, message: @message).call if @attachments.empty? && @enrollment && !self.class.protected_message?(@message) && !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message)
      if correction
        @intake, @answer = correction.values_at(:intake, :answer)
        return self
      end
      parser = ChatIntake.new(@enrollment, message: @message) if @attachments.empty?
      @intake = parser&.call
      coach = CoachAnswerer.new(household: @household, user: @user, enrollment: @enrollment,
        message: @message, attachments: @attachments, daily_report: @intake, daily_rejection: parser&.rejection, savings_intake: @intake)
      reference = coach.call
      if coach.deterministic?
        @answer = reference
      else
        narrator = Narrator.new(user_message: @message,
          answer_packet: { kind: "savings_challenge", basis: "participant-approved savings ledger and explicitly scoped baseline",
            write_state: "no_write", fallback_response: reference,
            guardrails: [ "90_day_total_not_monthly", "approved_new_money_reserved_only", "partial_coverage_is_not_full_household", "feelings_optional_private" ],
            available_product_modules: @available_product_modules, verified_facts: coach.answer_facts }.compact,
          history: @history, persona: @persona, approved_content: @approved_content)
        @answer = narrator.call
        @supplied_content_context = narrator.supplied_content_context
      end
      self
    end

    # Caller holds the household lock and has rechecked current challenge access.
    # The proposal is not a financial draft until the participant chooses Yes.
    def persist!(assistant_message)
      if @goal_cents
        SavingsChatCard.where(savings_enrollment: @enrollment, kind: "goal", status: "pending")
          .for_picture(@household.financial_generation).update_all(status: "closed", state: {})
        plan = @enrollment.reload.current_accepted_plan_version
        @card = SavingsChatCard.create!(savings_enrollment: @enrollment, chat_message: assistant_message, kind: "goal",
          input: { target_cents: @goal_cents, expected_plan_version_id: plan&.id,
            weekly_cents: @weekly_cents,
            reason: plan ? "Changed my challenge goal in chat" : "",
            financial_baseline_version_id: plan&.financial_baseline_version_id, baseline_digest: plan&.baseline_digest,
            spending_changes: plan&.spending_changes || [] })
      elsif @intake&.dig(:kind) == "daily_report"
        @card = SavingsChatCard.create!(savings_enrollment: @enrollment, chat_message: assistant_message, kind: "daily_report", input: @intake)
      elsif @intake&.dig(:kind).in?(%w[contribution withdrawal])
        @card = SavingsChatCard.create!(savings_enrollment: @enrollment, chat_message: assistant_message, kind: "savings", input: @intake)
      end
      @session.update!(active_topic: @topic)
      (@card || @continued_card&.reload)&.as_api_json
    end

    private

    def review_continuation
      return false unless @message.match?(/\A\s*(?:yes|yeah|yep|ok(?:ay)?)(?:[, ]+(?:please|save it|save|do it))?[.!]?\s*\z/i)
      @continued_card = SavingsChatCard.joins(:chat_message).where(chat_messages: { chat_session_id: @session.id }, status: "pending")
        .for_picture(@household.financial_generation).order(:id).last
      return false unless @continued_card
      @topic = @session.active_topic
      step = { "savings" => "Review savings", "goal" => "Yes on the goal card", "daily_report" => "Save on the check-in card" }.fetch(@continued_card.kind)
      @answer = "Your card is still below. Choose #{step} to check and confirm it; nothing has been saved from this reply."
      true
    end

    def money(cents)
      whole, fraction = cents.abs.divmod(100)
      "#{cents.negative? ? '-' : ''}$#{whole}#{fraction.zero? ? '' : ".#{fraction.to_s.rjust(2, '0')}"}"
    end

    def pattern_turn
      previous = @session.active_topic
      if !@message.match?(PATTERNS) && previous["type"] == "challenge_patterns" && self.class.pattern_continuation?(@message, choices: previous["choices"])
        choices = Array(previous["choices"])
        # A named merchant wins ("the one at Kmart"); then ordinals, testing
        # "second" before "first|one" so "the second one" picks the second.
        text = @message.downcase
        selected = choices.find { |choice| choice["merchant"].present? && text.include?(choice["merchant"].to_s.downcase) }
        unless selected || @message.match?(/\?|\A\s*(?:what|which|how|why)\b/i)
          selected = if @message.match?(/\b(?:second|two|2nd|latter)\b/i) then choices[1]
          elsif @message.match?(/\b(?:first|one|1st|former)\b/i) then choices[0]
          end
        end
        if selected && !@message.match?(/\b(?:neither|not|don.t|no)\b/i)
          @goal_cents = 50_000
          @answer = "Spending half as much at #{selected['merchant']} could free about #{money(selected['monthly_impact_cents'].to_i)} a month, based on the months recorded. How about a $500 cushion over your 90 days to keep surprises off the card? Choose Yes on the card if that feels comfortable; nothing changes until you do. Only new money you actually set aside counts toward the goal."
          @topic = { type: "challenge_goal" }
          return true
        elsif @message.match?(/\b(?:what (?:do|should)|which|choose|comfortable|this or|options?)\b/i)
          @answer = choices_question(choices)
          @topic = previous
          return true
        end
      end
      return false unless @message.match?(PATTERNS)
      @patterns = SpendingPatterns::Analyzer.new(@household, today: @enrollment.local_today).call
      choices = @patterns[:candidate_changes].first(2)
      @topic = { type: "challenge_patterns", choices: choices }
      coverage = @patterns[:coverage]
      present = coverage[:months].select { |row| row[:spending_cents] }.map { |row| Date.iso8601("#{row[:month]}-01").strftime("%b") }
      missing = coverage[:months].any? { |row| row[:spending_cents].nil? }
      window = if missing
        "I only see purchases for #{present.to_sentence}:"
      else
        "From #{present.first} to #{present.last} in the recorded purchases,"
      end
      flexible = @patterns[:discretionary_merchants].first(2).map { |row| "#{row[:label]} (#{money(row[:total_cents])})" }
      observed = if flexible.any?
        "#{window} #{flexible.to_sentence} #{flexible.one? ? 'was your biggest flexible spend' : 'were your biggest flexible spends'}."
      else
        "I don't have enough purchases in flexible categories to suggest a cut yet. A store name alone doesn't tell me what you needed."
      end
      cluster = @patterns[:small_purchase_clusters].first
      waterfall = cluster ? " #{cluster[:purchase_count]} small buys of #{money(cluster[:threshold_cents])} or less stacked up around #{cluster[:label]} — #{money(cluster[:total_cents])} altogether." : ""
      impact = choices.first
      estimate = impact ? " Spending half as much at #{impact[:merchant]} could free about #{money(impact[:monthly_impact_cents])} a month, based on the months recorded." : ""
      reference = "#{observed}#{waterfall}#{estimate} #{choices_question(choices)}"
      narrator = PatternsNarrator.new(user_message: @message, persona: @persona, history: @history, approved_content: @approved_content,
        answer_packet: { kind: "challenge_patterns", write_state: "no_write", fallback_response: reference, available_product_modules: @available_product_modules,
          verified_facts: { merchants: @patterns[:discretionary_merchants].first(2), cluster: cluster, choices: choices,
            months_with_purchases: present, missing_months: missing } })
      @answer = narrator.call
      @supplied_content_context = narrator.supplied_content_context
      true
    end

    def choices_question(choices)
      return "Would you like to review a statement in Statements, or tell me one spending habit you'd like to change?" if choices.empty?
      options = choices.first(2).map { |choice| choice[:merchant] || choice["merchant"] }
      "Would you feel more comfortable cutting back on #{options.join(' or ')}?"
    end

    def goal_turn
      message = GoalAmount.normalize(@message)
      message = message.sub(/\A\s*actually[, ]*/i, "").sub(/\blet['’]?s just\b/i, "lets")
      suggestion = message.match?(GOAL) && message.match?(/\b(?:comfortable|suggest|choose|pick|help|recommend)\b/i)
      return false if message.match?(/\b(?:household|paid|spent|saved|withdrew|card balance)\b/i) || (message.match?(/\bset aside\b/i) && !self.class.weekly_offer?(message))
      return false if message.match?(/\bdebt\b/i) && !message.match?(/\b(?:challenge|savings|90.day)\s+(?:goal|target)\b/i)
      standalone = self.class.amount_reply?(message, session: @session)
      weekly = message.match?(GoalAmount::WEEKLY)
      return false unless message.match?(GOAL_CHANGE) || message.match?(GOAL_DESIRE) || message.match?(GOAL_STATEMENT) || standalone || suggestion || self.class.weekly_offer?(message)
      malformed = message.match?(/(?:\$\s*|\b(?:to|at|be|save|set aside)\s+)[0-9][0-9,]*\.\d{3,}/i)
      amounts = message.scan(/\$\s*(#{AMOUNT_SOURCE})#{AMOUNT_END}/).flatten
      amounts = message.scan(/\b(?:to|at|of|be|is|save|do|set aside)\s+(#{AMOUNT_SOURCE})#{AMOUNT_END}/i).flatten if amounts.empty?
      amounts = [ message.match(BARE_AMOUNT)[1] ] if amounts.empty? && standalone && message.match?(BARE_AMOUNT)
      # A polite request with an explicit amount is still a proposal. A question
      # about reaching the existing goal must not silently propose the default.
      return false if !suggestion && amounts.empty? && message.match?(/\?|\A\s*(?:can|should|could|would|what|how)\b/i)
      # The requested destination wins even when the old amount alone has a
      # dollar sign. "Be $500 instead of $400" also names a destination.
      destination = message[/\b(?:goal|target)\s+(?:to\s+be|to|at|be|of|is)\s+\$?\s*(#{AMOUNT_SOURCE})#{AMOUNT_END}/i, 1]
      replacement = destination || message[/\b(?:to|at|be|save|set aside|make it|let['’]?s (?:do|go with|make it)|go with)\s+\$?\s*(#{AMOUNT_SOURCE})#{AMOUNT_END}/i, 1]
      chosen = replacement || (amounts.first if amounts.one?)
      @goal_cents = if malformed
        nil
      elsif chosen
        HouseholdFinance::Money.chat_cents(chosen) rescue nil
      elsif suggestion && amounts.empty?
        50_000
      end
      unless @goal_cents&.between?(1, 2_147_483_647)
        @goal_cents = nil
        @topic = { type: "challenge_goal" }
        @answer = "What comfortable amount would you like as your goal for the whole 90 days? Nothing has changed."
        return true
      end
      if weekly && amounts.one?
        @weekly_cents = @goal_cents
        @goal_cents = (@weekly_cents * 90 + 3) / 7
        unless @goal_cents.between?(1, 2_147_483_647)
          @goal_cents = nil
          @answer = "That weekly amount is too large for a 90-day goal. What smaller amount would feel comfortable? Nothing has changed."
          @topic = { type: "challenge_goal" }
          return true
        end
      end
      @topic = { type: "challenge_goal" }
      pace = @weekly_cents ? " At #{money(@weekly_cents)} a week, #{money(@weekly_cents)} × 90 ÷ 7 = #{money(@goal_cents)}, rounded to the nearest cent." : ""
      @answer = "I've set up a #{money(@goal_cents)} target for you to confirm below, for the whole 90 days.#{pace} A cushion can keep surprises off the card; keep essentials and required payments covered first. Review the card below and choose Yes if that feels comfortable, or change it. Your target only changes when you confirm; this doesn’t add saved money."
      true
    end

    def progress_turn
      return false unless @message.match?(PROGRESS)
      projection = Projection.new(@enrollment).call
      calendar = ParticipantSerializer.calendar(@enrollment)
      withdrawn_more = projection[:reporting_known] && projection[:reported_cents].negative?
      amount = if withdrawn_more
        "You've taken out #{money(-projection[:reported_cents])} more than you've set aside"
      elsif projection[:reporting_known]
        "You've set aside #{money(projection[:reported_cents])}"
      else
        "You haven't reported savings yet, so I don't know your total"
      end
      target = if projection[:target_cents]
        withdrawn_more ? "; your goal is #{money(projection[:target_cents])}" : " toward your #{money(projection[:target_cents])} goal"
      else
        " and you can choose a comfortable goal whenever you're ready"
      end
      due = [ 30, 60, 90 ].select { |day| @enrollment.starts_on + day - 1 <= @enrollment.local_today }
      reviewed = SavingsCheckpoint.where(savings_enrollment: @enrollment).where.not(current_version_id: nil).pluck(:milestone_day)
      ready = (due - reviewed).first
      dates = calendar[:checkpoints].map { |day, date| "Day #{day}: #{Date.iso8601(date).strftime('%b %-d')}" }.join("; ")
      @answer = "#{amount}#{target}. #{dates}. #{ready ? "Day #{ready} is ready to review: open Today, then Checkpoints, to look back at what you saved and noticed." : 'At each checkpoint you can look back at your saved amounts and check-ins in Today → Checkpoints.'} Estimates and spending cuts are separate from money you actually set aside."
      true
    end
  end
end
