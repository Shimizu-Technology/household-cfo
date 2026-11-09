module HouseholdFinance
  class MiaSetupGuide
    SETUP_REQUEST = "Help me set up my household. Please ask me one simple question at a time."
    GOAL_CHANGE_REQUEST = /\A(?:please\s+)?(?:change|update|set)\s+(?:my|our)\s+(?:(?:main|primary)\s+(?:money\s+)?|money\s+)?goal\s+to\s+(.+?)[.!]?\z/i

    class << self
      def goal_change_request?(value)
        normalized(value).match?(GOAL_CHANGE_REQUEST)
      end

      def setup_request?(value)
        normalized(value).match?(/\A(?:please )?(?:resume|continue)(?: my| our)? (?:household )?setup[.!]?\z/i) || normalized(value).casecmp?(SETUP_REQUEST) || normalized(value).match?(/\A(?:please\s+)?(?:help\s+me\s+(?:to\s+)?|let['’]?s\s+)?(?:set\s*up|start\s+setting\s+up)\s+(?:my|our)\s+household[.!]?\z/i)
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
      return complete_message if setup_status.missing_field_keys.empty?
      field = setup_status.open_field_keys.first
      return MiaSetupCardReply.question(field, card: MiaSetupCard.new(household), previous: nil) if field

      "That's everything for now. Still to add when you're ready: #{setup_status.as_json[:missing_fields].map { |item| item[:label].downcase }.to_sentence}."
    end

    def setup_request_message(value)
      return after_apply_message if self.class.setup_request?(value)
      return unless value.to_s.squish.match?(/\Awhat (?:else )?do you (?:still )?need from me to finish (?:setting up|setup)\??\z/i)

      return complete_message if setup_status.missing_field_keys.empty?

      missing = setup_status.as_json[:missing_fields].map { |field| field[:label].downcase }.to_sentence
      "Still to add: #{missing}. #{after_apply_message}"
    end

    def next_missing_field
      setup_status.open_field_keys.first
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
