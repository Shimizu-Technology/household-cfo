require "test_helper"
require "timeout"

class HouseholdFinanceMiaProviderAdmissionTest < ActiveSupport::TestCase
  test "admits only the configured number of simultaneous provider calls" do
    provider = "admission-#{SecureRandom.hex(6)}"
    entered = Queue.new
    release = Queue.new
    results = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          result = HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 2).call do
            entered << true
            release.pop
            :completed
          end
          results << result
        end
      end
    end

    Timeout.timeout(3) { 2.times { entered.pop } }
    rejected = HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 2).call { flunk("saturated admission must not run the provider block") }

    assert_nil rejected
    assert_equal 2, ProviderCallLease.where(provider: provider).count

    2.times { release << true }
    threads.each(&:join)
    assert_equal [ :completed, :completed ], 2.times.map { results.pop }.sort
    assert_equal 0, ProviderCallLease.where(provider: provider).count
  ensure
    2.times { release << true } if defined?(release)
    threads&.each { |thread| thread.join(1) }
    ProviderCallLease.where(provider: provider).delete_all if defined?(provider)
  end

  test "reclaims an expired slot" do
    provider = "expired-#{SecureRandom.hex(6)}"
    ProviderCallLease.create!(
      provider: provider,
      slot: 1,
      owner_token: SecureRandom.uuid,
      expires_at: 1.second.ago
    )

    result = HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 1).call { :reclaimed }

    assert_equal :reclaimed, result
    assert_equal 0, ProviderCallLease.where(provider: provider).count
  end
end
