module ChallengePrivacy
  class RecordSelector
    TYPES = %w[document_source source_review_version savings_entry_version savings_plan_version chat_message].freeze
    def initialize(enrollment) = @enrollment = enrollment
    def call(raw)
      raise ArgumentError, "Select at most twenty exact records" unless raw.is_a?(Array) && raw.length <= 20
      rows = raw.map do |value|
        value = value.to_h.symbolize_keys
        raise ArgumentError, "Use only record_type and record_id" unless value.keys.sort == %i[record_id record_type]
        raise ArgumentError, "Select a supported exact record" unless TYPES.include?(value[:record_type]) && value[:record_id].is_a?(Integer) && value[:record_id].positive?
        row = { record_type: value[:record_type], record_id: value[:record_id] }
        resolve!(row)
        row
      end.sort_by { |row| [ row[:record_type], row[:record_id] ] }
      raise ArgumentError, "Select each record once" unless rows.uniq.length == rows.length
      rows
    end

    def resolve!(row)
      row = row.symbolize_keys
      id = row.fetch(:record_id)
      case row.fetch(:record_type)
      when "document_source"
        record = @enrollment.household.financial_document_imports.find(id)
        raise Access::Denied, "The selected source is unavailable" unless record.source_available? && SourceRetention.available?(record)
        record
      when "source_review_version" then SourceReviewVersion.where(household_id: @enrollment.household_id).find(id)
      when "savings_entry_version" then SavingsEntryVersion.where(savings_enrollment: @enrollment).find(id)
      when "savings_plan_version" then SavingsPlanVersion.where(savings_enrollment: @enrollment).find(id)
      when "chat_message"
        ChatMessage.joins(:chat_session).where(chat_sessions: { household_id: @enrollment.household_id, user_id: @enrollment.user_id, cohort_id: @enrollment.cohort_id }).find(id)
      else raise Access::Denied, "The selected record is unavailable"
      end
    end
  end
end
