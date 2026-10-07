class WorkosEmailDeliveryLimit < ApplicationRecord
  self.filter_attributes += [ :identity_digest ]

  def self.consume!(identity_digest:, now: Time.current)
    # The unique constraint serializes concurrent first use; with_lock also
    # serializes later requests across app instances without relying on cache.
    record = create_or_find_by!(identity_digest: identity_digest) do |bucket|
      bucket.window_started_at = now
    end
    record.with_lock do
      if record.window_started_at <= now - 60.seconds
        record.window_started_at = now
        record.delivery_count = 0
      end
      raise WorkosBrowserAuth::EmailChallenges::RateLimited, "Please wait before requesting another code" if record.delivery_count >= 3
      record.delivery_count += 1
      record.save!
    end
  end
end
