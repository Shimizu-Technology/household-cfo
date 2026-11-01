module SavingsChallenge
  # The challenge's conversation boundary. Numbers are computed here; the
  # narrator can coach ordinary turns but cannot rewrite verified answers.
  class ChatTurn
    PATTERNS = /\b(?:patterns?|waterfall|subscriptions?)\b/i.freeze
    GOAL = /\b(?:goal|target)\b/i.freeze
    GOAL_CHANGE = /\b(?:change|set|make|update|lower|raise|switch|drop|bump|aim)\b.{0,50}\b(?:goal|target)\b|\b(?:goal|target)\b.{0,40}\$\s*\d|\blet['’]?s do\s+\$\s*\d/i.freeze
    PROGRESS = /\b(?:how am i doing|where am i|day\s*(?:30|60|90)|30\s*[\/,]\s*60|checkpoints?)\b/i.freeze

    def self.special?(message, session:)
      return false if HouseholdFinance::MiaCoachAnswerer.prompt_injection?(message) || message.match?(/\bhousehold\b/i) || money_report?(message)
      message.match?(PATTERNS) || message.match?(GOAL_CHANGE) || message.match?(PROGRESS) ||
        (message.match?(GOAL) && message.match?(/\b(?:comfortable|suggest|choose|pick|help|recommend)\b/i)) ||
        (session.active_topic["type"] == "challenge_patterns" && pattern_continuation?(message, choices: session.active_topic["choices"]))
    end

    def self.money_report?(message)
      return false if message.match?(/\?|\A\s*(?:how|why|what|where|can|could|should|do|did|is|are)\b/i)
      message.match?(/\b(?:spent|bought|paid|saved|withdrew|set aside|no spending|no-spend)\b/i)
    end

    def self.pattern_continuation?(message, choices: [])
      normalized = message.downcase.squish.sub(/[.!]\z/, "")
      return true if Array(choices).any? { |choice| choice["merchant"].to_s.downcase == normalized }
      return false if message.match?(/\b(?:spent|bought|paid|saved|withdrew|set aside|budget|category|income|salary|paycheck|account|asset|balance)\b/i)
      message.match?(/\b(?:first|second|choose|cut back|try|comfortable|say(?:ing)? no|reduce|rather|what (?:do|should)|options?)\b/i)
    end

    def self.replay_payload(payload, session:)
      id = payload.dig("challenge_chat_card", "id")
      return payload unless id
      card = SavingsChatCard.joins(:chat_message).where(chat_messages: { chat_session_id: session.id }).find_by(id: id)
      payload.merge("challenge_chat_card" => card&.as_api_json)
    end

    def initialize(household:, user:, enrollment:, session:, message:, attachments: [], persona:, history:, approved_content: [])
      @household, @user, @enrollment, @session, @message, @attachments = household, user, enrollment, session, message.to_s, attachments
      @persona, @history, @approved_content = persona, history, approved_content
      @topic = {}
    end

    attr_reader :answer, :intake, :supplied_content_context, :patterns

    def call
      @supplied_content_context = []
      if @enrollment && @attachments.empty? && !self.class.money_report?(@message) && !HouseholdFinance::MiaCoachAnswerer.prompt_injection?(@message) && !::Mia::CrisisBoundary.hopeless?(@message) && !HouseholdFinance::MoneyMovementText.food_insecurity?(@message)
        return self if pattern_turn || goal_turn || progress_turn
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
            guardrails: [ "90_day_total_not_monthly", "approved_new_money_reserved_only", "partial_coverage_is_not_full_household", "feelings_optional_private" ], verified_facts: coach.answer_facts }.compact,
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
            reason: plan ? "Changed my challenge goal in chat" : "",
            financial_baseline_version_id: plan&.financial_baseline_version_id, baseline_digest: plan&.baseline_digest,
            spending_changes: plan&.spending_changes || [] })
      elsif @intake&.dig(:kind) == "daily_report"
        @card = SavingsChatCard.create!(savings_enrollment: @enrollment, chat_message: assistant_message, kind: "daily_report", input: @intake)
      end
      @session.update!(active_topic: @topic)
      @card&.as_api_json
    end

    private

    def money(cents)
      "$#{cents.div(100)}.#{cents.modulo(100).to_s.rjust(2, '0')}"
    end

    def pattern_turn
      previous = @session.active_topic
      if !@message.match?(PATTERNS) && previous["type"] == "challenge_patterns" && self.class.pattern_continuation?(@message, choices: previous["choices"])
        choices = Array(previous["choices"])
        selected = choices.find.with_index do |choice, index|
          @message.downcase.include?(choice["merchant"].to_s.downcase) || (!@message.match?(/\?|\A\s*(?:what|which|how|why)\b/i) && @message.match?(/\b(?:#{index == 0 ? 'first|one|1' : 'second|two|2'})\b/i))
        end
        if selected && !@message.match?(/\b(?:neither|not|don.t|no)\b/i)
          @goal_cents = 50_000
          @answer = "Spending half as much at #{selected['merchant']} could free about #{money(selected['monthly_impact_cents'].to_i)} in a month like the ones recorded. How about a $500 cushion over your 90 days to keep surprises off the card? Review the goal below; it only changes when you choose Yes, and spending less does not count until you actually set new money aside."
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
      labels = coverage[:months].map { |row| Date.iso8601("#{row[:month]}-01").strftime("%b %Y") }
      flexible = @patterns[:discretionary_merchants].first(3).map { |row| "#{row[:label]}: #{money(row[:total_cents])}" }
      observed = flexible.any? ? "Purchases in categories marked flexible include #{flexible.join('; ')}." : "I don't have enough purchases in flexible categories to suggest a cut yet; a store name alone doesn't tell me what you needed."
      cluster = @patterns[:small_purchase_clusters].first
      waterfall = cluster ? " Small purchases of $25 or less cluster around #{cluster[:label]}: #{cluster[:purchase_count]} purchases totaling #{money(cluster[:total_cents])}; that may be a useful habit to notice, without guessing why." : ""
      recurring = @patterns[:possible_subscriptions].first
      subscription = recurring ? " #{recurring[:merchant]} repeats around the same date at about #{money(recurring[:typical_amount_cents])}; check whether it's a subscription you still want." : ""
      missing = coverage[:months].select { |row| row[:spending_cents].nil? }.map { |row| Date.iso8601("#{row[:month]}-01").strftime("%B") }
      limits = "I looked at #{labels.join(', ')}. #{coverage[:note]}#{missing.any? ? " I have no confirmed purchases for #{missing.join(' or ')}; that isn't a zero-spending month." : ''}"
      @answer = "#{observed}#{waterfall}#{subscription} #{limits} #{choices_question(choices)}"
      true
    end

    def choices_question(choices)
      return "Would you like to review a statement in Statements, or tell me one spending habit you'd like to change?" if choices.empty?
      options = choices.first(2).map { |choice| "#{choice[:label] || choice['label']} (about #{money(choice[:monthly_impact_cents] || choice['monthly_impact_cents'])} a month if you spend half as much)" }
      "Would you feel more comfortable choosing #{options.join(' or ')}? These are estimates from the months recorded; keep essentials and required payments covered."
    end

    def goal_turn
      suggestion = @message.match?(GOAL) && @message.match?(/\b(?:comfortable|suggest|choose|pick|help|recommend)\b/i)
      return false if @message.match?(/\b(?:household|paid|spent|saved|set aside|withdrew|card balance)\b/i)
      return false if @message.match?(/\bdebt\b/i) && !@message.match?(/\b(?:challenge|savings|90.day)\s+(?:goal|target)\b/i)
      return false unless @message.match?(GOAL_CHANGE) || suggestion
      amounts = @message.scan(/\$\s*(\d[\d,]*(?:\.\d{1,2})?)(?![\d.])/).flatten
      amounts = @message.scan(/\b(?:to|at|of)\s+(\d[\d,]*(?:\.\d{1,2})?)(?![\d.])/).flatten if amounts.empty?
      # A polite request with an explicit amount is still a proposal. A question
      # about reaching the existing goal must not silently propose the default.
      return false if !suggestion && amounts.empty? && @message.match?(/\?|\A\s*(?:can|should|could|would|what|how)\b/i)
      replacement = @message[/\b(?:to|at)\s+\$?\s*(\d[\d,]*(?:\.\d{1,2})?)(?![\d.])/i, 1]
      chosen = if amounts.length > 1
        replacement
      else
        amounts.first
      end
      @goal_cents = if chosen
        HouseholdFinance::Money.chat_cents(chosen) rescue nil
      elsif suggestion && amounts.empty?
        50_000
      end
      unless @goal_cents&.between?(1, 2_147_483_647)
        @goal_cents = nil
        @answer = "What comfortable amount would you like as your goal for the whole 90 days? Nothing has changed."
        return true
      end
      @topic = { type: "challenge_goal" }
      @answer = "How does #{money(@goal_cents)} over your 90 days feel? A cushion can keep surprises off the card, but food, housing and required payments come first. Review the card below and choose Yes, change the amount, or leave it for now; nothing has changed yet."
      true
    end

    def progress_turn
      return false unless @message.match?(PROGRESS)
      projection = Projection.new(@enrollment).call
      calendar = ParticipantSerializer.calendar(@enrollment)
      amount = projection[:reporting_known] ? "You've set aside #{money(projection[:reported_cents])}" : "You haven't reported savings yet, so I don't know your total"
      target = projection[:target_cents] ? " toward your #{money(projection[:target_cents])} goal" : " and you can choose a comfortable goal whenever you're ready"
      due = [ 30, 60, 90 ].select { |day| @enrollment.starts_on + day - 1 <= @enrollment.local_today }
      reviewed = SavingsCheckpoint.where(savings_enrollment: @enrollment).where.not(current_version_id: nil).pluck(:milestone_day)
      ready = (due - reviewed).first
      dates = calendar[:checkpoints].map { |day, date| "Day #{day}: #{Date.iso8601(date).strftime('%b %-d')}" }.join('; ')
      @answer = "#{amount}#{target}. #{dates}. #{ready ? "Day #{ready} is ready to review: open Today, then Checkpoints, to look back at what you saved and noticed." : 'At each checkpoint you can look back at your saved amounts and check-ins in Today → Checkpoints.'} Estimates and spending cuts are separate from money you actually set aside."
      true
    end
  end
end
