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
          result = HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 2, wait_ms: 0).call do
            entered << true
            release.pop
            :completed
          end
          results << result
        end
      end
    end

    Timeout.timeout(3) { 2.times { entered.pop } }
    rejected = HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 2, wait_ms: 0).call { flunk("saturated admission must not run the provider block") }

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
      HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 1, wait_ms: 0).call { raise "provider failed" }
    end

    assert_equal :reused, HouseholdFinance::MiaProviderAdmission.new(provider: provider, limit: 1, wait_ms: 0).call { :reused }
  end


  test "waits briefly for a busy provider slot before falling back" do
    admission = HouseholdFinance::MiaProviderAdmission.new(provider: "waiting-#{SecureRandom.hex(6)}", limit: 1, wait_ms: 500)
    attempts = 0
    admission.define_singleton_method(:acquire) do |_connection|
      attempts += 1
      attempts >= 3 ? 1 : nil
    end
    admission.define_singleton_method(:release) { |_connection, _slot| true }

    assert_equal :admitted_after_wait, admission.call { :admitted_after_wait }
    assert_operator attempts, :>=, 3
  end
end
