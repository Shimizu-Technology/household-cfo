module HouseholdFinance
  module Operations
    class Base
      StaleOperation = Class.new(ArgumentError)
      STALE_MESSAGE = "Budget changed since Mia drafted this. Ask Mia to draft a fresh edit."
      attr_accessor :release_membership

      def initialize(household)
        @household = household
      end

      def normalized_input(raw_input)
        normalize(raw_input.to_h.deep_symbolize_keys).deep_symbolize_keys
      end

      def prepare(raw_input)
        input = normalized_input(raw_input)
        ensure_plan!(input)
        subject = subject_for(input, lock: false)
        before = canonical_snapshot(subject, input, lock: false).deep_stringify_keys
        PreparedOperation.new(
          household_id: household.id,
          operation_key: self.class::KEY,
          operation_version: self.class::VERSION,
          normalized_input: input.deep_stringify_keys,
          subject: subject_locator(subject),
          before_snapshot: before,
          predicted_after_snapshot: predicted_after(before.deep_dup, input).deep_stringify_keys,
          before_fingerprint: PreparedOperation.fingerprint(before)
        )
      end

      def execute!(prepared, source:)
        input = prepared.normalized_input.deep_symbolize_keys
        @stale_input = input
        subject = subject_for(input, lock: true)
        validate_execution!(subject, input, prepared: prepared, source: source)
        current = canonical_snapshot(subject, input, lock: true).deep_stringify_keys
        unless ActiveSupport::SecurityUtils.secure_compare(
          PreparedOperation.fingerprint(current), prepared.before_fingerprint
        )
          raise StaleOperation, stale_message
        end

        mutate!(subject, input, prepared: prepared)
      end

      def after_snapshot(subject, prepared)
        canonical_after_snapshot(subject, prepared.normalized_input.deep_symbolize_keys, prepared: prepared).deep_stringify_keys
      end

      def verify_after!(_predicted, _actual)
        true
      end

      private

      attr_reader :household

      attr_reader :stale_input

      def manager(input)
        AnnualBudgetManager.new(household, year: input.fetch(:year))
      end

      def ensure_plan!(input)
        manager(input).ensure_plan_inside_household_lock!
      end

      def validate_execution!(_subject, _input, prepared:, source:)
        true
      end

      def subject_locator(subject)
        { "type" => subject.class.name, "id" => subject.id }
      end

      def category_snapshot(category)
        {
          id: category.id,
          name: category.name,
          stack_key: category.stack_key,
          stack_label: category.stack_label,
          active: category.active,
          sort_order: category.sort_order
        }
      end

      def expense_snapshots(category, lock: false, additional_names: [], ids: [])
        names = ([ category.name ] + Array(additional_names)).filter_map { |name| name.to_s.squish.presence&.downcase }.uniq
        scope = household.expense_items.where("LOWER(label) IN (?) OR id IN (?)", names, Array(ids).presence || [ 0 ]).order(:id)
        scope = scope.lock if lock
        scope.map do |expense|
          {
            id: expense.id,
            label: expense.label,
            stack_key: expense.stack_key,
            amount_cents: expense.amount_cents,
            cadence: expense.cadence,
            active: expense.active
          }
        end
      end

      def stale_message
        STALE_MESSAGE
      end
    end
  end
end
