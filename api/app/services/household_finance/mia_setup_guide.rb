module HouseholdFinance
  class MiaSetupGuide
    REVIEW_BOUNDARY = "Tell me here and I’ll prepare a review card; nothing changes until you apply it."
    NEXT_QUESTIONS = {
      "household_name" => "What would you like to call this household?",
      "primary_goal" => "What is the main money goal you want this household to work toward?",
      "primary_income" => "What is this household’s primary monthly take-home income? Enter 0 if there is none.",
      "fixed_expenses" => "About how much are this household’s fixed essentials each month? Enter 0 if there are none.",
      "flexible_spend" => "About how much does this household spend flexibly each month? Enter 0 if there is none."
    }.freeze

    def initialize(household)
      @household = household
    end

    def after_apply_message
      missing_field = setup_status.missing_field_keys.first
      return complete_message unless missing_field

      "Next setup question: #{NEXT_QUESTIONS.fetch(missing_field)} #{REVIEW_BOUNDARY}"
    end

    private

    attr_reader :household

    def setup_status
      @setup_status ||= SetupStatus.new(household)
    end

    def complete_message
      "Your starting picture is complete. For your first coaching step, ask me “What should I focus on first this month?” and I’ll use your approved numbers."
    end
  end
end
