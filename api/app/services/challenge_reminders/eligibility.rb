module ChallengeReminders
  class Eligibility
    # S07 supplies an approved daily-attendance reader. No log, reminder or
    # delivery result is evidence of spending, no-spend, or participant activity.
    class NoAttendanceSuppression
      def completed?(enrollment:, local_on:) = false
    end

    def initialize(attendance: Attendance.new) = @attendance = attendance
    def reason(enrollment, preference, at: Time.current)
      ChallengePrivacy::Access.participant!(enrollment.household, enrollment.user, enrollment, active: true)
      return "participant_unavailable" unless enrollment.status == "active"
      local = at.in_time_zone(enrollment.time_zone)
      return "outside_personal_day" unless local.to_date.between?(enrollment.starts_on, enrollment.ends_on)
      return "preference_disabled" unless preference.enabled
      return "before_local_time" if local.strftime("%H:%M") < preference.local_time
      return "quiet_hours" if preference.quiet?(local)
      return "attendance_confirmed" if @attendance.completed?(enrollment: enrollment, local_on: local.to_date) == true
      nil
    rescue ChallengePrivacy::Access::Denied, SavingsChallenge::AccessPolicy::Unavailable, ActiveRecord::RecordNotFound
      "participant_unavailable"
    end
  end
end
