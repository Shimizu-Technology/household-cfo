module HouseholdFinance
  class MiaSetupGuide
    SETUP_REQUEST = "Help me set up my household. Please ask me one simple question at a time."
    GOAL_CHANGE_REQUEST = /\A(?:please\s+)?(?:change|update|set)\s+(?:my|our)\s+(?:(?:main|primary)\s+(?:money\s+)?|money\s+)?goal\s+to\s+(.+?)[.!]?\z/i
    REVIEW_BOUNDARY = "Tell me here and I’ll prepare a review card; nothing changes until you apply it."
    NEXT_QUESTIONS = {
      "household_name" => "What would you like to call this household?",
      "primary_goal" => "What is the main money goal you want this household to work toward?",
      "primary_income" => "What is this household’s primary monthly take-home income? Enter 0 if there is none.",
      "fixed_expenses" => "About how much are this household’s fixed essentials each month? Enter 0 if there are none.",
      "flexible_spend" => "About how much is your household’s everyday spending each month? Enter 0 if there is none.",
      "debt_payment" => "How much are your household’s debt minimum payments each month? Say ‘no debt payments’ if there are none."
    }.freeze

    RESUME_QUESTIONS = {
      "household_name" => "What name should I put on your household plan?",
      "primary_goal" => "What would you most like your money plan to help you do?",
      "primary_income" => "Coming back to income: about how much do you bring home each month?",
      "fixed_expenses" => "Back to your bills: what monthly amount should we review for fixed essentials?",
      "flexible_spend" => "For everyday spending, what monthly amount would you like to review?",
      "debt_payment" => "What monthly debt minimum should we review? You can say no debt payments."
    }.freeze

    RETRY_QUESTIONS = {
      "household_name" => "Which household name would you like to review?",
      "primary_goal" => "Which money goal should we put on your plan?",
      "primary_income" => "What monthly take-home income should I put on the review card?",
      "fixed_expenses" => "Which monthly total should we review for your must-pay bills?",
      "flexible_spend" => "What monthly estimate should we review for everyday costs?",
      "debt_payment" => "What debt minimums should we review, or are there no debt payments?"
    }.freeze

    class << self
      def pending_question_field(missing, messages)
        recent = Array(messages).reverse.find { |item| item.to_h.symbolize_keys[:role].to_s == "assistant" && item.to_h.symbolize_keys[:content].to_s.include?("Next setup question:") }
        missing.find { |key| recent && [ NEXT_QUESTIONS[key], RESUME_QUESTIONS[key], RETRY_QUESTIONS[key] ].compact.any? { |question| recent.to_h.symbolize_keys[:content].to_s.include?(question) } } || missing.first
      end

      def goal_change_request?(value)
        normalized(value).match?(GOAL_CHANGE_REQUEST)
      end

      def setup_request?(value)
        normalized(value).match?(/\A(?:please )?(?:resume|continue)(?: my| our)? (?:household )?setup[.!]?\z/i) || normalized(value).casecmp?(SETUP_REQUEST) || normalized(value).match?(/\A(?:please\s+)?(?:help\s+me\s+(?:to\s+)?|let['’]?s\s+)?(?:set\s*up|start\s+setting\s+up)\s+(?:my|our)\s+household[.!]?\z/i)
      end

      def question_message(field, resume: false)
        question = (resume ? RESUME_QUESTIONS : NEXT_QUESTIONS)[field.to_s]
        return unless question

        "Next setup question: #{question} #{REVIEW_BOUNDARY}"
      end

      def other_question_pending?(active_thread)
        thread = active_thread.to_h.deep_symbolize_keys
        thread[:status] == "needs_clarification" && thread[:type] != "household_setup"
      end

      def server_question_asked?(field, active_thread:, recent_messages:)
        return false if other_question_pending?(active_thread)
        recent = Array(recent_messages).reverse.find do |message|
          turn = message.to_h.deep_symbolize_keys
          turn[:role] == "assistant" && (turn[:content].to_s.include?("Next setup question:") || turn[:content].to_s.include?("Setup is paused."))
        end
        return false unless recent
        text = recent.to_h.deep_symbolize_keys[:content].to_s
        return false if text.include?("Setup is paused.")
        questions = [ question_message(field), question_message(field, resume: true), "Next setup question: #{RETRY_QUESTIONS[field.to_s]} #{REVIEW_BOUNDARY}" ]
        questions << "Next setup question: About how much does this household spend flexibly each month? Enter 0 if there is none. #{REVIEW_BOUNDARY}" if field.to_s == "flexible_spend"
        questions.any? { |question| text.end_with?(question) }
      end

      def resume_question_message(field, messages)
        last = Array(messages).reverse.find { |item| item.to_h.symbolize_keys[:role].to_s == "assistant" && item.to_h.symbolize_keys[:content].to_s.include?("Next setup question:") }
        if last && last.to_h.symbolize_keys[:content].to_s.include?(RESUME_QUESTIONS[field.to_s].to_s)
          "Next setup question: #{RETRY_QUESTIONS.fetch(field.to_s)} #{REVIEW_BOUNDARY}"
        else
          question_message(field, resume: true)
        end
      end

      private

      def normalized(value)
        value.to_s.unicode_normalize(:nfkc).squish
      end
    end

    def initialize(household)
      @household = household
    end

    def after_apply_message
      return complete_message if setup_status.complete?
      missing_field = setup_status.missing_field_keys.first
      return complete_message unless missing_field

      self.class.question_message(missing_field)
    end

    def setup_request_message(value)
      return after_apply_message if self.class.setup_request?(value)
      return unless value.to_s.squish.match?(/\Awhat (?:else )?do you (?:still )?need from me to finish (?:setting up|setup)\??\z/i)

      return complete_message if setup_status.complete?

      missing = setup_status.as_json[:missing_fields].map { |field| field[:label].downcase }.to_sentence
      "Still to add: #{missing}. #{after_apply_message}"
    end

    def next_missing_field
      setup_status.missing_field_keys.first unless setup_status.complete?
    end

    private

    attr_reader :household

    def setup_status
      @setup_status ||= SetupStatus.new(household)
    end

    def complete_message
      "Your household setup is complete. Ask me “How am I doing this month?” to see what your plan leaves."
    end
  end
end
