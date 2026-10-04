module ChallengeReminders
  class Delivery
    LEASE = 2.minutes
    MAX_ATTEMPTS = 5
    MAX_BATCH = 100
    GENERIC_MESSAGE = { title: "Your daily check-in".freeze, body: "Open the app when you are ready for your daily check-in.".freeze, app_path: "/".freeze }.freeze
    class DisabledEmail
      def enabled? = false
      def supports_idempotency? = false
      def idempotency_namespace = "disabled"
      def deliver(**_arguments) = raise(ArgumentError, "Email delivery is disabled")
    end

    def initialize(email: ProductionEmail.new, attendance: Attendance.new)
      @email, @eligibility = email, Eligibility.new(attendance: attendance)
    end

    def call(limit: MAX_BATCH)
      ChallengeReminder.due.order(:next_attempt_at, :id).limit(Integer(limit).clamp(1, MAX_BATCH)).pluck(:id).each { |id| dispatch(id) }
    end

    # Queue admission is only a latency optimization. Failure leaves the primary
    # outbox intact for the recurring recovery service or explicit operator run.
    def self.request_dispatch
      ChallengeReminderRecoveryJob.perform_later
      true
    rescue StandardError
      false
    end

    def dispatch(id)
      token = claim(id)
      deliver_claim(id, token) if token
    end

    def claim(id)
      with_reminder(id) do |reminder, enrollment, preference|
        next unless reminder.status == "pending" && reminder.next_attempt_at <= Time.current
        next if halt_or_wait(reminder, enrollment, preference)
        if reminder.attempts >= MAX_ATTEMPTS
          terminal(reminder, "failed", "attempts_exhausted")
          next
        end
        idempotent = reminder.channel == "in_app" || @email.supports_idempotency? == true
        # An uncertain earlier send may only retry through the same adapter
        # idempotency contract. A change of provider must not re-send it.
        namespace = reminder.channel == "in_app" ? "in_app_db_v1" : @email.idempotency_namespace
        unless namespace.is_a?(String) && /\A[a-zA-Z0-9_.:-]{1,100}\z/.match?(namespace)
          terminal(reminder, "cancelled", "channel_disabled")
          next
        end
        if reminder.attempts.positive? && (reminder.provider_namespace != namespace || (reminder.provider_idempotent && !idempotent))
          terminal(reminder, "unknown", "delivery_unknown")
          next
        end
        token = SecureRandom.uuid
        reminder.update!(status: "leased", lease_token: token, lease_expires_at: Time.current + LEASE,
          attempts: reminder.attempts + 1, provider_idempotent: idempotent, provider_namespace: namespace)
        token
      end
    end

    def deliver_claim(id, token)
      with_reminder(id) do |reminder, enrollment, preference|
        next unless reminder.status == "leased" && reminder.lease_token == token && reminder.lease_expires_at > Time.current
        next if halt_or_wait(reminder, enrollment, preference)
        if reminder.channel == "in_app"
          terminal(reminder, "delivered", "available", delivered_at: Time.current)
          next
        end
        if reminder.provider_namespace != @email.idempotency_namespace || reminder.provider_idempotent != (@email.supports_idempotency? == true)
          terminal(reminder, "unknown", "delivery_unknown", delivery_uncertain: true)
          next
        end
        # Hold the household lock through the bounded provider request. A
        # consent revocation committing first prevents this send. The adapter
        # must set its own short network timeout and not log recipient/payload.
        begin
          verdict = @email.deliver(recipient: enrollment.user.reload.email, delivery_key: reminder.delivery_key, message: GENERIC_MESSAGE)
          case verdict
          when :delivered then terminal(reminder, "delivered", "delivered", delivered_at: Time.current, delivery_uncertain: false)
          when :not_sent then retry_or_fail(reminder)
          else uncertain(reminder)
          end
        rescue StandardError
          uncertain(reminder)
        end
      end
    end

    def recover(limit: MAX_BATCH)
      ids = ChallengeReminder.where(status: "leased").where("lease_expires_at <= ?", Time.current).order(:id).limit(Integer(limit).clamp(1, MAX_BATCH)).pluck(:id)
      ids.each do |id|
        with_reminder(id) do |reminder, enrollment, preference|
          next unless reminder.status == "leased" && reminder.lease_expires_at <= Time.current
          reminder.update!(delivery_uncertain: true) if reminder.channel == "email"
          if reminder.channel == "email" && !reminder.provider_idempotent
            terminal(reminder, "unknown", "delivery_unknown")
            next
          end
          next if halt_or_wait(reminder, enrollment, preference)
          if reminder.channel == "in_app"
            retry_or_fail(reminder, reason: "lease_recovered")
          elsif reminder.provider_idempotent && reminder.attempts < MAX_ATTEMPTS
            retry_or_fail(reminder, reason: "lease_recovered")
          else
            terminal(reminder, "unknown", "delivery_unknown")
          end
        end
      end
    end

    private

    def with_reminder(id)
      reminder = ChallengeReminder.find(id)
      ApplicationRecord.transaction do
        reminder.household.lock!
        reminder.reload.lock!
        enrollment = SavingsEnrollment.find(reminder.savings_enrollment_id)
        preference = ChallengeReminderPreference.find(reminder.challenge_reminder_preference_id)
        yield reminder, enrollment, preference
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def halt_or_wait(reminder, enrollment, preference)
      reason = @eligibility.reason(enrollment, preference)
      reason ||= "outside_personal_day" if reminder.local_on != Time.current.in_time_zone(enrollment.time_zone).to_date
      reason ||= "channel_disabled" if reminder.channel == "email" && !@email.enabled?
      return false unless reason
      if reason.in?(%w[quiet_hours before_local_time])
        reminder.update!(status: "pending", reason_code: reason, next_attempt_at: Time.current + 5.minutes, lease_token: nil, lease_expires_at: nil)
      else
        terminal(reminder, "cancelled", reason)
      end
      true
    end

    def terminal(reminder, status, reason, **attributes)
      reminder.update!(status: status, reason_code: reason, lease_token: nil, lease_expires_at: nil, **attributes)
    end
    def uncertain(reminder)
      reminder.update!(delivery_uncertain: true)
      reminder.provider_idempotent && reminder.attempts < MAX_ATTEMPTS ? retry_or_fail(reminder) : terminal(reminder, "unknown", "delivery_unknown")
    end
    def retry_or_fail(reminder, reason: "retry_wait")
      if reminder.attempts >= MAX_ATTEMPTS
        if reminder.delivery_uncertain
          terminal(reminder, "unknown", "delivery_unknown")
        else
          terminal(reminder, "failed", "attempts_exhausted")
        end
      else
        reminder.update!(status: "pending", reason_code: reason, lease_token: nil, lease_expires_at: nil,
          next_attempt_at: Time.current + [ 60 * (2**[ reminder.attempts - 1, 0 ].max), 900 ].min.seconds)
      end
    end
  end
end
