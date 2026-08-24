require "test_helper"
require "timeout"

class HouseholdFinanceMiaProviderAdmissionTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

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

    2.times { release << true }
    threads.each(&:join)
    assert_equal [ :completed, :completed ], 2.times.map { results.pop }.sort
  ensure
    2.times { release << true } if defined?(release)
    threads&.each { |thread| thread.join(1) }
  end

  test "releases the provider slot after the call raises" do
    provider = "raised-#{SecureRandom.hex(6)}"

    assert_raises(RuntimeError) do
      HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 1).call { raise "provider failed" }
    end

    assert_equal :reused, HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 1).call { :reused }
  end
end
