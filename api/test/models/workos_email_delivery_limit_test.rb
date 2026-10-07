require "test_helper"

class WorkosEmailDeliveryLimitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "concurrent first use admits only three deliveries and the window resets" do
    digest = SecureRandom.hex(32)
    ready = Queue.new
    gate = Queue.new
    results = Queue.new
    now = Time.current
    workers = 10.times.map do
      Thread.new do
        ready << true
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection do
          WorkosEmailDeliveryLimit.consume!(identity_digest: digest, now: now)
          results << :allowed
        rescue WorkosBrowserAuth::EmailChallenges::RateLimited
          results << :limited
        rescue StandardError => error
          results << error
        end
      end
    end
    10.times { ready.pop }
    10.times { gate << true }
    workers.each(&:join)
    outcomes = 10.times.map { results.pop }
    assert_equal 3, outcomes.count(:allowed), outcomes.inspect
    assert_equal 7, outcomes.count(:limited), outcomes.inspect
    assert_equal 1, WorkosEmailDeliveryLimit.where(identity_digest: digest).count
    assert_equal 3, WorkosEmailDeliveryLimit.find_by!(identity_digest: digest).delivery_count
    WorkosEmailDeliveryLimit.consume!(identity_digest: digest, now: now + 61.seconds)
    assert_equal 1, WorkosEmailDeliveryLimit.find_by!(identity_digest: digest).delivery_count
  ensure
    workers&.each(&:join)
    WorkosEmailDeliveryLimit.where(identity_digest: digest).delete_all if digest
  end
end
