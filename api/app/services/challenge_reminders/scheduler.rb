module ChallengeReminders
  class Scheduler
    MAX_BATCH = 100
    def initialize(attendance: Attendance.new, email: ProductionEmail.new)
      @eligibility, @email = Eligibility.new(attendance: attendance), email
    end

    def call(limit: MAX_BATCH)
      limit = Integer(limit).clamp(1, MAX_BATCH)
      # Read bounded chunks without starving later programs behind the first
      # hundred rows. Dispatch has its own strict total batch bound.
      SavingsEnrollment.where(status: "active").find_each(batch_size: limit) { |enrollment| schedule(enrollment.id) }
    end

    def schedule(enrollment_id)
      enrollment = SavingsEnrollment.find(enrollment_id)
      ApplicationRecord.transaction do
        enrollment.household.lock!
        enrollment.reload
        # Avoid writing defaults for an unavailable participant.
        ChallengePrivacy::Access.participant!(enrollment.household, enrollment.user, enrollment, active: true)
        return unless enrollment.status == "active"
        local = Time.current.in_time_zone(enrollment.time_zone)
        return unless local.to_date.between?(enrollment.starts_on, enrollment.ends_on)
        ChallengeReminderPreference::CHANNELS.each do |channel|
          next if channel == "email" && !@email.enabled?
          preference = ChallengeReminderPreference.find_or_create_by!(savings_enrollment: enrollment, channel: channel) do |record|
            record.assign_attributes(household: enrollment.household, participant_user_id: enrollment.user_id, **ChallengeReminderPreference.defaults(channel))
          end
          next if local.strftime("%H:%M") < preference.local_time || @eligibility.reason(enrollment, preference)
          ChallengeReminder.find_or_create_by!(savings_enrollment: enrollment, local_on: local.to_date, channel: channel) do |reminder|
            reminder.assign_attributes(household: enrollment.household, participant_user_id: enrollment.user_id,
              challenge_reminder_preference: preference, delivery_key: SecureRandom.uuid, next_attempt_at: Time.current)
          end
        end
      end
    rescue ChallengePrivacy::Access::Denied, SavingsChallenge::AccessPolicy::Unavailable, ActiveRecord::RecordNotFound
      nil
    end
  end
end
