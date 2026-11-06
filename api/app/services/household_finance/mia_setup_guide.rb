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

    class << self
      def pending_question_field(missing, messages)
        recent = Array(messages).reverse.find { |item| item.to_h.symbolize_keys[:role].to_s == "assistant" && item.to_h.symbolize_keys[:content].to_s.include?("Next setup question:") }
        missing.find { |key| recent && [ NEXT_QUESTIONS[key], RESUME_QUESTIONS[key] ].compact.any? { |question| recent.to_h.symbolize_keys[:content].to_s.include?(question) } } || missing.first
      end

      def goal_change_request?(value)
        normalized(value).match?(GOAL_CHANGE_REQUEST)
      end

      def setup_request?(value)
        normalized(value).casecmp?(SETUP_REQUEST) || normalized(value).match?(/\A(?:please\s+)?(?:help\s+me\s+(?:to\s+)?|let['’]?s\s+)?(?:set\s*up|start\s+setting\s+up)\s+(?:my|our)\s+household[.!]?\z/i)
      end

      def question_message(field, resume: false)
        question = (resume ? RESUME_QUESTIONS : NEXT_QUESTIONS)[field.to_s]
        return unless question

        "Next setup question: #{question} #{REVIEW_BOUNDARY}"
      end

      def server_question_asked?(field, active_thread:, recent_messages:)
        # Recover after a clarification or unrelated answer replaces the active
        # topic. Only a server-authored setup question establishes this context.
        questions = [ question_message(field), question_message(field, resume: true) ].compact
        if field.to_s == "flexible_spend"
          questions << "Next setup question: About how much does this household spend flexibly each month? Enter 0 if there is none. #{REVIEW_BOUNDARY}"
        end
        Array(recent_messages).reverse.any? do |message|
          turn = message.to_h.deep_symbolize_keys
          turn[:role] == "assistant" && questions.any? { |question| turn[:content].to_s.end_with?(question) }
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
