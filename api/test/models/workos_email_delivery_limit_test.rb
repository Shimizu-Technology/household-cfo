require "test_helper"

class WorkosEmailDeliveryLimitTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "concurrent first use admits only three deliveries and the window resets" do
    digests = 3.times.map { SecureRandom.hex(32) }
    budgets = [ { identity_digest: digests[0], maximum: 3, window: 60.seconds },
      { identity_digest: digests[1], maximum: 10, window: 1.hour }, { identity_digest: digests[2], maximum: 5, window: 1.hour } ]
    ready = Queue.new
    gate = Queue.new
    results = Queue.new
    now = Time.current
    workers = 10.times.map do
      Thread.new do
        ready << true
        gate.pop
        ActiveRecord::Base.connection_pool.with_connection do
          WorkosEmailDeliveryLimit.consume_many!(budgets: budgets, now: now)
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
    assert_equal 3, WorkosEmailDeliveryLimit.where(identity_digest: digests).count
    assert_equal [ 3, 3, 3 ], digests.map { |digest| WorkosEmailDeliveryLimit.find_by!(identity_digest: digest).delivery_count }
    WorkosEmailDeliveryLimit.consume_many!(budgets: budgets, now: now + 61.seconds)
    assert_equal [ 1, 4, 4 ], digests.map { |digest| WorkosEmailDeliveryLimit.find_by!(identity_digest: digest).delivery_count }
  ensure
    workers&.each(&:join)
    WorkosEmailDeliveryLimit.where(identity_digest: digests).delete_all if digests
  end

  test "denial of the last locked source budget rolls back earlier increments and window resets" do
    digests = 3.times.map { SecureRandom.hex(32) }.sort
    budgets = [ { identity_digest: digests[0], maximum: 3, window: 60.seconds },
      { identity_digest: digests[1], maximum: 10, window: 1.hour }, { identity_digest: digests[2], maximum: 1, window: 1.hour } ]
    now = Time.current
    WorkosEmailDeliveryLimit.consume_many!(budgets: budgets, now: now)
    before = WorkosEmailDeliveryLimit.where(identity_digest: digests).order(:identity_digest).pluck(:delivery_count, :window_started_at, :updated_at)
    WorkosEmailDeliveryLimit.transaction do
      assert_raises(WorkosBrowserAuth::EmailChallenges::RateLimited) do
        WorkosEmailDeliveryLimit.consume_many!(budgets: budgets, now: now + 61.seconds)
      end
    end
    assert_equal before, WorkosEmailDeliveryLimit.where(identity_digest: digests).order(:identity_digest).pluck(:delivery_count, :window_started_at, :updated_at)
    WorkosEmailDeliveryLimit.consume_many!(budgets: budgets, now: now + 1.hour)
    assert_equal [ 1, 1, 1 ], digests.map { |digest| WorkosEmailDeliveryLimit.find_by!(identity_digest: digest).delivery_count }
  ensure
    WorkosEmailDeliveryLimit.where(identity_digest: digests).delete_all if digests
  end

  test "retry waits until every blocked minute and hourly budget can accept again" do
    digests = 3.times.map { SecureRandom.hex(32) }.sort
    budgets = [ { identity_digest: digests[0], maximum: 3, window: 60.seconds },
      { identity_digest: digests[1], maximum: 10, window: 1.hour }, { identity_digest: digests[2], maximum: 5, window: 1.hour } ]
    now = Time.current
    [ [ 3, now ], [ 10, now - 20.minutes ], [ 5, now - 10.minutes ] ].each_with_index do |(count, started), index|
      WorkosEmailDeliveryLimit.create!(identity_digest: digests[index], delivery_count: count, window_started_at: started)
    end
    before = WorkosEmailDeliveryLimit.where(identity_digest: digests).order(:identity_digest).pluck(:delivery_count, :window_started_at, :updated_at)
    error = assert_raises(WorkosBrowserAuth::EmailChallenges::RateLimited) do
      WorkosEmailDeliveryLimit.consume_many!(budgets: budgets, now: now)
    end
    assert_in_delta 50.minutes.to_i, error.retry_after_sec, 1
    assert_equal before, WorkosEmailDeliveryLimit.where(identity_digest: digests).order(:identity_digest).pluck(:delivery_count, :window_started_at, :updated_at)
    WorkosEmailDeliveryLimit.consume_many!(budgets: budgets, now: now + error.retry_after_sec)
    assert_equal [ 1, 1, 1 ], digests.map { |digest| WorkosEmailDeliveryLimit.find_by!(identity_digest: digest).delivery_count }
  ensure
    WorkosEmailDeliveryLimit.where(identity_digest: digests).delete_all if digests
  end
end
