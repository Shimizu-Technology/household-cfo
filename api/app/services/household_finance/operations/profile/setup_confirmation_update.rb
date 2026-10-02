module HouseholdFinance
  module Operations
    module Profile
      class SetupConfirmationUpdate < Base
        KEY = "profile.setup_confirmation.update"
        VERSION = 1
        CONFIRMABLE_FIELDS = SetupUpdater::INPUT_KEYS.map(&:to_s).freeze

        private

        def normalize(input)
          if input.fetch(:updates, {}).to_h.any?
            raise ArgumentError, "Setup confirmation cannot change household values; prepare typed household operations first"
          end
          requested = Array(input[:confirmed_fields].presence || input[:confirm_only_fields]).map(&:to_s)
          unconfirmed = Array(input[:unconfirmed_fields]).map(&:to_s)
          fields = requested.select { |field| field.in?(CONFIRMABLE_FIELDS) }.uniq.sort
          removed = unconfirmed.select { |field| field.in?(CONFIRMABLE_FIELDS) }.uniq.sort
          unless (fields.any? || removed.any?) && fields.length == requested.length && removed.length == unconfirmed.length && (fields & removed).empty?
            raise ArgumentError, "Choose valid setup fields to confirm"
          end

          touched = (fields + removed).sort
          expected = input.fetch(:expected_values, {}).to_h.stringify_keys.slice(*touched)
          unless expected.empty? || expected.keys.sort == touched
            raise ArgumentError, "Expected setup values must match the reviewed fields"
          end

          { confirmed_fields: fields, unconfirmed_fields: removed, expected_values: expected.transform_values { |value| value.to_s } }
        end

        def ensure_plan!(_input)
          true
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(subject, input, lock:)
          subject.reload if lock
          relevant = input.fetch(:confirmed_fields) + input.fetch(:unconfirmed_fields)
          { confirmed_fields: Array(subject.confirmed_setup_fields).map(&:to_s).select { |field| field.in?(relevant) }.sort }
        end

        def predicted_after(before, input)
          confirmed = before.fetch("confirmed_fields") + input.fetch(:confirmed_fields)
          { confirmed_fields: (confirmed - input.fetch(:unconfirmed_fields)).uniq.sort }
        end

        def mutate!(subject, input, prepared:)
          ensure_profile_fields_are_present!(subject, input.fetch(:confirmed_fields))
          confirmed = Array(subject.confirmed_setup_fields).map(&:to_s) + input.fetch(:confirmed_fields)
          subject.update!(confirmed_setup_fields: (confirmed - input.fetch(:unconfirmed_fields)).uniq)
          subject.reload
        end

        def validate_execution!(_household, input, prepared: _prepared, source: _source)
          expected = input.fetch(:expected_values)
          return if expected.empty?

          current = DataPresenter.new(household).setup_values.stringify_keys
          mismatch = expected.any? do |field, value|
            field = field.to_s
            canonical_value(field, current.fetch(field)) != canonical_value(field, value)
          end
          return unless mismatch

          raise Operations::Base::StaleOperation,
            "Household values changed since Mia prepared these confirmations. Ask Mia to draft a fresh review. Nothing changed."
        end

        def canonical_after_snapshot(subject, input, prepared:)
          canonical_snapshot(subject, input, lock: false)
        end

        def verify_after!(predicted, actual)
          return true if predicted == actual

          raise Operations::Runner::InvalidPreparedOperation, "The setup confirmations did not match the reviewed fields. Nothing changed."
        end

        def ensure_profile_fields_are_present!(subject, fields)
          fields.each do |field|
            next unless field.in?(%w[household_name primary_goal])
            value = field == "household_name" ? subject.name : subject.primary_goal
            raise ArgumentError, "#{field.humanize} cannot be confirmed while blank" if value.blank?
          end
        end

        def canonical_value(field, value)
          if field.in?(MiaActionDraftHouseholdCommands::SETUP_MONEY_KEYS.map(&:to_s)) || field == "target_runway_months"
            return "" if value.to_s.strip.blank?

            return BigDecimal(value.to_s).to_s("F")
          end

          value.to_s.squish
        end

        def stale_message
          "Household numbers changed since Mia prepared this review. Ask Mia to draft a fresh update."
        end
      end
    end
  end
end
