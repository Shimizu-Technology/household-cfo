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

  test "checks a failed admission connection back in before sleeping" do
    fake_pool = Class.new do
      attr_reader :checked_out

      def with_connection
        @checked_out = true
        yield Object.new
      ensure
        @checked_out = false
      end
    end.new
    admission = HouseholdFinance::MiaProviderAdmission.new(
      provider: "pool-release-#{SecureRandom.hex(6)}",
      limit: 1,
      wait_ms: 120,
      connection_pool: fake_pool
    )
    admission.define_singleton_method(:acquire) { |_connection| nil }
    sleep_states = []
    admission.define_singleton_method(:sleep) do |_duration|
      sleep_states << fake_pool.checked_out
      Thread.pass
    end

    assert_nil admission.call { flunk("saturated admission must not run the provider block") }
    assert_not_empty sleep_states
    assert_equal [ false ], sleep_states.uniq
  end

  test "counts connection checkout time against the admission deadline" do
    attempts = 0
    fake_pool = Class.new do
      def with_connection
        sleep(0.08)
        yield Object.new
      end
    end.new
    admission = HouseholdFinance::MiaProviderAdmission.new(
      provider: "checkout-deadline-#{SecureRandom.hex(6)}",
      limit: 1,
      wait_ms: 40,
      connection_pool: fake_pool
    )
    admission.define_singleton_method(:acquire) do |_connection|
      attempts += 1
      nil
    end

    assert_nil admission.call { flunk("expired admission must not run the provider block") }
    assert_equal 0, attempts
  end

  test "falls back after the bounded wait without invoking the provider" do
    admission = HouseholdFinance::MiaProviderAdmission.new(provider: "deadline-#{SecureRandom.hex(6)}", limit: 1, wait_ms: 120)
    admission.define_singleton_method(:acquire) { |_connection| nil }
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = admission.call { flunk("timed-out admission must not run the provider block") }
    elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000

    assert_nil result
    assert_operator elapsed_ms, :>=, 100
    assert_operator elapsed_ms, :<, 500
  end
end
