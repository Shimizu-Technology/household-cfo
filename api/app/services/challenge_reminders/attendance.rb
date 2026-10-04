module ChallengeReminders
  class Attendance
    # Purchases, reflections, chat and reminder timestamps are not a completed
    # daily report. A current participant-approved check-in is required.
    def completed?(enrollment:, local_on:)
      head = SavingsDailyCheckIn.find_by(savings_enrollment: enrollment, local_on: local_on)
      version = head&.current_version
      return false unless version && version.savings_daily_check_in_id == head.id &&
        version.savings_enrollment_id == enrollment.id && version.approved_by_user_id == enrollment.user_id &&
        version.approved_at && version.version_number.positive? && version.spending_state.in?(%w[spending no_spend])
      projection = SavingsChallenge::Daily::DayProjection.new(enrollment, user: enrollment.user, local_on: local_on).call
      projection[:check_in_version_id] == version.id && projection[:canonical_links_changed] == false &&
        projection[:no_spend_discrepancy] == false
    rescue ArgumentError, ActiveRecord::RecordNotFound
      false
    end
  end
end
