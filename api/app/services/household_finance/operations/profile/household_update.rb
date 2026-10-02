module HouseholdFinance
  module Operations
    module Profile
      class HouseholdUpdate < Base
        KEY = "profile.household.update"
        VERSION = 1
        FIELDS = %i[name primary_goal location stage].freeze

        private

        def normalize(input)
          values = {}
          values[:name] = bounded(input[:name], 120, allow_blank: false) if input.key?(:name)
          values[:primary_goal] = bounded(input[:primary_goal], 500, allow_blank: true) if input.key?(:primary_goal)
          values[:location] = bounded(input[:location], 120, allow_blank: true) if input.key?(:location)
          values[:stage] = bounded(input[:stage], 120, allow_blank: true) if input.key?(:stage)
          raise ArgumentError, "Choose at least one household profile field to update" if values.empty?

          values
        end

        def ensure_plan!(_input)
          true
        end

        def subject_for(_input, lock:)
          lock ? household.lock! : household
        end

        def canonical_snapshot(subject, input, lock:)
          subject.reload if lock
          selected_fields = input.keys & FIELDS
          { household: { id: subject.id }.merge(selected_fields.to_h { |field| [ field, subject.public_send(field) ] }) }
        end

        def predicted_after(before, input)
          { household: before.fetch("household").merge(input.stringify_keys) }
        end

        def mutate!(subject, input, prepared:)
          subject.update!(input)
          subject
        end

        def canonical_after_snapshot(subject, input, prepared:)
          canonical_snapshot(subject, input, lock: false)
        end

        def bounded(value, limit, allow_blank:)
          text = value.to_s.squish
          raise ArgumentError, "Household name cannot be blank" if !allow_blank && text.blank?

          text.truncate(limit, omission: "…").presence
        end

        def stale_message
          "Household profile changed since Mia prepared this review. Ask Mia to draft a fresh update."
        end
      end
    end
  end
end
