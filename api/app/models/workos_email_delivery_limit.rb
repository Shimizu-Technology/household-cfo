class WorkosEmailDeliveryLimit < ApplicationRecord
  self.filter_attributes += [ :identity_digest ]

  def self.consume!(identity_digest:, maximum: 3, window: 60.seconds, now: Time.current)
    consume_many!(budgets: [ { identity_digest: identity_digest, maximum: maximum, window: window } ], now: now)
  end

  def self.consume_many!(budgets:, now: Time.current)
    # A fixed lock order and unique constraint serialize both first use and
    # existing buckets across app instances. A denial rolls back every budget.
    transaction(requires_new: true) do
      locked = budgets.sort_by { |budget| budget.fetch(:identity_digest) }.map do |budget|
        record = create_or_find_by!(identity_digest: budget.fetch(:identity_digest)) do |bucket|
          bucket.window_started_at = now
        end
        record.lock!
        if record.window_started_at <= now - budget.fetch(:window)
          record.window_started_at = now
          record.delivery_count = 0
        end
        [ record, budget ]
      end
      blocked = locked.filter_map do |record, budget|
        record.window_started_at + budget.fetch(:window) - now if record.delivery_count >= budget.fetch(:maximum)
      end
      raise WorkosBrowserAuth::EmailChallenges::RateLimited.new(retry_after_sec: blocked.max) if blocked.any?
      locked.each do |record, _|
        record.delivery_count += 1
        record.save!
      end
    end
  end
end
