module SetupHelp
  class Serializer
    def self.request(record, permissions: nil)
      payload = { id: record.id, status: record.status, reason: record.reason, reason_label: SetupSupportRequest::REASONS.fetch(record.reason),
        participant_name: record.requested_by_user.full_name, user_id: record.requested_by_user_id,
        household_id: record.household_id, cohort_id: record.cohort_id, program_name: record.cohort&.name,
        lock_version: record.lock_version, review_state: review_state(record), review_id: record.financial_restart_review_id,
        review_expires_at: record.financial_restart_review&.expires_at&.iso8601,
        created_at: record.created_at.iso8601, updated_at: record.updated_at.iso8601 }
      payload[:permissions] = permissions if permissions
      payload
    end
    def self.review_state(record)
      review = record.financial_restart_review
      return "none" unless review
      return review.status if review.status.in?(%w[applied canceled])
      return "expired" if review.expires_at <= Time.current
      return "stale" if review.financial_generation != record.household.financial_generation
      "pending"
    end
  end
end
