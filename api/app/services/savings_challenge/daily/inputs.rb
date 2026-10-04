module SavingsChallenge
  module Daily
    module Inputs
      MAX_AMOUNT_CENTS = 2_147_483_647
      module_function

      def text!(value, limit:, required: false)
        return nil if value.nil? && !required
        raise ArgumentError, "Use bounded participant text" unless value.instance_of?(String) && value.length <= limit && (!required || value.strip.present?)
        value
      end

      def boolean!(value)
        raise ArgumentError, "Use an explicit true or false choice" unless value == true || value == false
        value
      end

      def splits!(value, amount)
        raise ArgumentError, "Review one to twenty explicit category splits" unless value.instance_of?(Array) && value.size.between?(1, 20)
        splits = value.map do |raw|
          raise ArgumentError, "Review category and exact cents for every split" unless raw.instance_of?(Hash)
          part = raw.deep_symbolize_keys
          SavingsChallenge::Inputs.keys!(part, required: %i[budget_category_id amount_cents])
          { budget_category_id: SavingsChallenge::Inputs.id!(part[:budget_category_id]),
            amount_cents: SavingsChallenge::Inputs.integer!(part[:amount_cents], minimum: 1, maximum: MAX_AMOUNT_CENTS) }
        end
        raise ArgumentError, "Category splits must equal the purchase" unless splits.sum { |part| part[:amount_cents] } == amount
        splits
      end

      def elapsed_date!(enrollment, value, future_draft: false)
        date = SavingsChallenge::Inputs.date!(value)
        finish = future_draft ? enrollment.ends_on : [ enrollment.ends_on, enrollment.local_today ].min
        raise ArgumentError, "Use a date within the personal challenge window" unless (enrollment.starts_on..finish).cover?(date)
        date
      end
    end
  end
end
