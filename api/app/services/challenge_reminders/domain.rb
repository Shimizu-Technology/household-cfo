require "digest"

module ChallengeReminders
  class Domain
    attr_reader :household, :user
    def initialize(household, user:) = (@household, @user = household, user)
    def enrollment(id) = SavingsEnrollment.find_by!(id: id, household: household, user: user)
    def authorize!(record, active: false) = ChallengePrivacy::Access.participant!(household, user, record, active: active)
    def digest(value) = Digest::SHA256.hexdigest(JSON.generate(value.deep_stringify_keys.sort.to_h))

    def normalize(action, raw)
      raw = raw.deep_symbolize_keys
      allowed = action == "preference" ? %i[enrollment_id channel enabled local_time quiet_start quiet_end policy_version expected_preference_id expected_lock_version] : %i[enrollment_id reminder_id expected_lock_version]
      raise ArgumentError, "Unexpected reminder field" unless (raw.keys - allowed).empty? && (allowed - raw.keys).empty?
      input = raw.dup
      input[:enrollment_id] = positive_id(input[:enrollment_id])
      input[:expected_lock_version] = nonnegative(input[:expected_lock_version])
      if action == "preference"
        raise ArgumentError, "Invalid reminder channel" unless input[:channel].in?(ChallengeReminderPreference::CHANNELS)
        raise ArgumentError, "Choose enabled or disabled" unless input[:enabled].in?([ true, false ])
        %i[local_time quiet_start quiet_end].each { |key| raise ArgumentError, "Use local HH:MM time" unless input[key].is_a?(String) && ChallengeReminderPreference::CLOCK.match?(input[key]) }
        raise ArgumentError, "Review generic reminder consent" unless input[:policy_version] == ChallengeReminderPreference::POLICY_VERSION
        input[:expected_preference_id] = positive_id(input[:expected_preference_id]) unless input[:expected_preference_id].nil?
      else
        input[:reminder_id] = positive_id(input[:reminder_id])
      end
      input
    end

    def snapshot(action, input)
      record = enrollment(input[:enrollment_id])
      authorize!(record, active: action == "preference" && input[:enabled])
      raise ChallengePrivacy::Access::Denied, "This enrollment is not active" if action == "preference" && input[:enabled] && record.status != "active"
      subject = action == "preference" ? preference(record, input[:channel]) : reminders(record).find(input[:reminder_id])
      if action == "preference"
        unless subject&.id == input[:expected_preference_id] && (subject&.lock_version || 0) == input[:expected_lock_version]
          raise HouseholdFinance::Operations::Base::StaleOperation, "Reminder preferences changed; review them again"
        end
      elsif subject.lock_version != input[:expected_lock_version] || subject.status != "delivered" || subject.channel != "in_app"
        raise HouseholdFinance::Operations::Base::StaleOperation, "This in-app reminder changed; reload it"
      end
      { id: subject&.id, lock_version: subject&.lock_version || 0, dismissed_at: action == "dismiss" ? subject.dismissed_at&.iso8601 : nil,
        enrollment_status: record.status, starts_on: record.starts_on.iso8601, ends_on: record.ends_on.iso8601, time_zone: record.time_zone }
    end

    def execute(action, input)
      ApplicationRecord.transaction do
        household.lock!
        input = normalize(action, input)
        snapshot(action, input)
        record = enrollment(input[:enrollment_id])
        subject = if action == "preference"
          preference(record, input[:channel]) || ChallengeReminderPreference.new(scope(record).merge(channel: input[:channel]))
        else
          reminders(record).find(input[:reminder_id])
        end
        if action == "preference"
          subject.update!(input.slice(:enabled, :local_time, :quiet_start, :quiet_end, :policy_version))
          unless subject.enabled
            reminders(record).where(channel: subject.channel, status: %w[pending leased]).find_each do |reminder|
              uncertain = reminder.delivery_uncertain || (reminder.channel == "email" && reminder.status == "leased")
              reminder.update!(status: "cancelled", reason_code: "preference_disabled", lease_token: nil, lease_expires_at: nil, delivery_uncertain: uncertain)
            end
          end
        else
          subject.update!(dismissed_at: subject.dismissed_at || Time.current, reason_code: "dismissed")
        end
        ChallengeReminderEvent.create!(scope(record).merge(actor_user: user, action: action, subject_type: subject.class.name,
          subject_id: subject.id, approved_values: input.except(:enrollment_id), created_at: Time.current))
      end
    end

    def read(enrollment_id)
      ApplicationRecord.transaction do
        household.lock!
        record = enrollment(positive_id(enrollment_id))
        authorize!(record)
        preferences = ChallengeReminderPreference::CHANNELS.map do |channel|
          pref = preference(record, channel)
          { id: pref&.id, lock_version: pref&.lock_version || 0, **(pref ? pref.attributes.symbolize_keys.slice(:channel, :enabled, :local_time, :quiet_start, :quiet_end, :policy_version) : ChallengeReminderPreference.defaults(channel)) }
        end
        current = reminders(record).where(channel: "in_app", local_on: record.local_today, status: "delivered", dismissed_at: nil).first
        { enrollment_id: record.id, time_zone: record.time_zone, preferences: preferences,
          reminder: current ? { id: current.id, lock_version: current.lock_version, local_on: current.local_on.iso8601, **Delivery::GENERIC_MESSAGE } : nil,
          email_delivery_enabled: ProductionEmail.new.enabled? == true, dismissal_is_check_in: false }
      end
    end

    def preference(record, channel) = ChallengeReminderPreference.find_by(savings_enrollment: record, channel: channel)
    def reminders(record) = ChallengeReminder.where(savings_enrollment: record)
    def scope(record) = { household: household, savings_enrollment: record, participant_user_id: record.user_id }

    private
    def positive_id(value)
      raise ArgumentError, "Use an exact record identifier" unless value.is_a?(Integer) && value.positive?
      value
    end
    def nonnegative(value)
      raise ArgumentError, "Use an exact lock version" unless value.is_a?(Integer) && value >= 0
      value
    end
  end
end
