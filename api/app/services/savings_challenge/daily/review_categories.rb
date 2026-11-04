module SavingsChallenge
  module Daily
    # The daily check-in and statements share BudgetCategory. Creating these
    # empty choices is audited; no budget, purchase or approval is created.
    class ReviewCategories
      DEFAULTS = { "non_discretionary" => "Bills & essentials", "discretionary" => "Everyday spending" }.freeze

      def self.ensure!(household:, user:)
        return unless user
        enrollment = SavingsEnrollment.find_by(household: household, user: user, status: "active")
        return unless enrollment

        ApplicationRecord.transaction do
          household.lock!
          FinancialDocuments::SourceReview::Domain.new(household, user: user).authorize!
          runner = HouseholdFinance::Operations::Runner.new(household, user: user)
          DEFAULTS.each do |stack, label|
            next if household.budget_categories.active.exists?(stack_key: stack)
            # Never revive an archived choice or change an existing choice's purpose.
            name = ([ label, "#{label} (default)" ] + (2..99).map { |i| "#{label} (default #{i})" }).find do |candidate|
              !household.budget_categories.where("LOWER(name) = ?", candidate.downcase).exists?
            end
            raise ArgumentError, "Choose a category for this purchase" unless name
            runner.run(operation_key: "savings.daily.category.create", input: { cohort_id: enrollment.cohort_id, name: name, stack_key: stack },
              idempotency_key: "statement-review-category:#{SecureRandom.uuid}")
          end
        end
      end

      # Only these broad defaults get broad merchant hints. A participant's
      # detailed budget and previously approved choices keep their own meaning.
      def self.suggestion(categories, merchant)
        text = merchant.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
        stack = if text.match?(/\b(?:rent|mortgage|power|gpa|water|gwa|waterworks|internet|phone|docomo|gta)\b/)
          "non_discretionary"
        elsif text.match?(/\b(?:ross|kmart|k mart|jamba|mcdonald\w*|port of mocha|amazon)\b/)
          "discretionary"
        end
        return unless stack
        label = DEFAULTS.fetch(stack)
        categories.find { |category| category.stack_key == stack && (category.name == label || category.name.start_with?("#{label} (default")) }&.id
      end
    end
  end
end
