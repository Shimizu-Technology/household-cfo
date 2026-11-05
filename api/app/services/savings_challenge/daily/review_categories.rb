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

      # Only recognized broad names can skip the category question. A sole
      # detailed choice can still be suggested, with the participant asked first.
      def self.broad?(category)
        return false unless category
        name = category.name.to_s.downcase.squish.sub(/ \(default(?: \d+)?\)\z/, "")
        names = category.stack_key == "discretionary" ? [ "everyday spending", "flexible spending" ] : [ "bills & essentials", "fixed essentials" ]
        names.include?(name)
      end

      # A single active choice in a stack can be suggested for review.
      # Detailed budgets and previously approved choices keep their own meaning.
      def self.suggestion(categories, merchant, event_type: "purchase")
        return unless event_type.in?(%w[purchase fee])
        text = merchant.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
        return if text.match?(/\b(?:transfers?|payments?|refunds?|reversals?)\b/)
        bank_fee = text.match?(/\b(?:bank|overdraft|maintenance) fee\b/) ||
          text.match?(/\Amonthly (?:service fee|maintenance fee|service charge)\z/) ||
          text.match?(/\bbank\b/) && text.match?(/\bservice (?:fee|charge)\b/)
        return if (event_type == "fee" || text.match?(/\bfees?\b/)) && !bank_fee
        stack = if event_type == "fee" || text.match?(/\b(?:rent|mortgage|power|electric(?:ity)?|utilities|utility|gpa|water|gwa|waterworks|internet|phone|mobile|insurance|docomo|gta|groceries|supermarkets?|payless|cost u less|fuel|gasoline|shell|mobil|service fee)\b/)
          "non_discretionary"
        elsif text.match?(/\b(?:restaurants?|grill|caf[eé]|coffee|pizza|juice|fast food|includes tip|netflix|streaming|subscription|department(?: store)?|discount(?: store)?|ross|kmart|k mart|jamba|mcdonald\w*|burger king|wendy s|kfc|taco bell|subway|popeyes|port of mocha|amazon|walmart|target|macy s)\b/)
          "discretionary"
        end
        return unless stack
        choices = categories.select { |category| category.active? && category.stack_key == stack }
        choices.one? ? choices.first.id : nil
      end
    end
  end
end
