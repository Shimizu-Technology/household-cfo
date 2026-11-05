module HouseholdFinance
  class MiaSetupGuide
    SETUP_REQUEST = "Help me set up my household. Please ask me one simple question at a time."
    REVIEW_BOUNDARY = "Tell me here and I’ll prepare a review card; nothing changes until you apply it."
    NEXT_QUESTIONS = {
      "household_name" => "What would you like to call this household?",
      "primary_goal" => "What is the main money goal you want this household to work toward?",
      "primary_income" => "What is this household’s primary monthly take-home income? Enter 0 if there is none.",
      "fixed_expenses" => "About how much are this household’s fixed essentials each month? Enter 0 if there are none.",
      "flexible_spend" => "About how much does this household spend flexibly each month? Enter 0 if there is none.",
      "debt_payment" => "How much are your household’s debt minimum payments each month? Say ‘no debt payments’ if there are none."
    }.freeze

    class << self
      def setup_request?(value)
        normalized(value).casecmp?(SETUP_REQUEST)
      end

      def question_message(field)
        question = NEXT_QUESTIONS[field.to_s]
        return unless question

        "Next setup question: #{question} #{REVIEW_BOUNDARY}"
      end

      def server_question_asked?(field, active_thread:, recent_messages:)
        # Recover after a clarification or unrelated answer replaces the active
        # topic. Only a server-authored setup question establishes this context.
        Array(recent_messages).reverse.any? do |message|
          turn = message.to_h.deep_symbolize_keys
          turn[:role] == "assistant" && question_message(field).present? && turn[:content].to_s.end_with?(question_message(field))
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
      missing_field = setup_status.missing_field_keys.first
      return complete_message unless missing_field

      self.class.question_message(missing_field)
    end

    def setup_request_message(value)
      return after_apply_message if self.class.setup_request?(value)
      return unless value.to_s.squish.match?(/\Awhat (?:else )?do you (?:still )?need from me to finish (?:setting up|setup)\??\z/i)

      return complete_message if setup_status.missing_field_keys.empty?

      missing = setup_status.as_json[:missing_fields].map { |field| field[:label].downcase }.to_sentence
      "Still to add: #{missing}. #{after_apply_message}"
    end

    def next_missing_field
      setup_status.missing_field_keys.first
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
