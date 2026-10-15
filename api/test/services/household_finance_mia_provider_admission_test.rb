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

  test "releases a slot acquired after the admission deadline without calling the provider" do
    fake_pool = Class.new do
      def with_connection
        yield Object.new
      end
    end.new
    admission = HouseholdFinance::MiaProviderAdmission.new(
      provider: "late-slot-#{SecureRandom.hex(6)}",
      limit: 1,
      wait_ms: 40,
      connection_pool: fake_pool
    )
    times = [ 0.0, 0.01, 0.05, 0.05, 0.05 ]
    released_slots = []
    admission.define_singleton_method(:monotonic_time) { times.shift || 0.05 }
    admission.define_singleton_method(:acquire) { |_connection| 1 }
    admission.define_singleton_method(:release) { |_connection, slot| released_slots << slot }

    assert_nil admission.call { flunk("late admission must not run the provider block") }
    assert_equal [ 1 ], released_slots
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

  test "a denied admission logs a structured line and a Sentry warning tagged with the call site" do
    admission = HouseholdFinance::MiaProviderAdmission.new(call_site: "mia_narrator", provider: "denied-#{SecureRandom.hex(6)}", limit: 2, wait_ms: 0)
    admission.define_singleton_method(:acquire) { |_connection| nil }
    captured = []
    logged = capture_log do
      with_sentry_capture(captured) do
        assert_nil admission.call { flunk("denied admission must not run the provider block") }
      end
    end

    line = logged.lines.find { |entry| entry.include?(HouseholdFinance::MiaProviderAdmission::DENIED_EVENT) }
    assert line, "expected a structured denied-admission log line"
    payload = JSON.parse(line[line.index("{")..])
    assert_equal "mia_narrator", payload.fetch("call_site")
    assert_equal "capacity_full", payload.fetch("reason")
    assert_equal 2, payload.fetch("limit")
    assert_equal 1, captured.length
    message, options = captured.first
    assert_equal HouseholdFinance::MiaProviderAdmission::DENIED_MESSAGE, message
    assert_equal :warning, options.fetch(:level)
    assert_equal({ mia_call_site: "mia_narrator", mia_admission_reason: "capacity_full" }, options.fetch(:tags))
    assert_equal [ HouseholdFinance::MiaProviderAdmission::DENIED_EVENT, "mia_narrator", "capacity_full" ], options.fetch(:fingerprint)
  end

  test "an admission database error is reported as a visible fallback without its message" do
    admission = HouseholdFinance::MiaProviderAdmission.new(call_site: "mia_intent", provider: "errored-#{SecureRandom.hex(6)}", limit: 1, wait_ms: 0)
    admission.define_singleton_method(:acquire) { |_connection| raise ActiveRecord::ConnectionTimeoutError, "secret detail" }
    captured = []
    logged = capture_log do
      with_sentry_capture(captured) do
        assert_nil admission.call { flunk("errored admission must not run the provider block") }
      end
    end

    refute_includes logged, "secret detail"
    _message, options = captured.sole
    assert_equal({ mia_call_site: "mia_intent", mia_admission_reason: "admission_error" }, options.fetch(:tags))
    assert_equal "ActiveRecord::ConnectionTimeoutError", options.fetch(:extra).fetch(:error_class)
  end

  test "an admitted call reports nothing" do
    captured = []
    with_sentry_capture(captured) do
      assert_equal :ok, HouseholdFinance::MiaProviderAdmission.new(call_site: "mia_intent", provider: "admitted-#{SecureRandom.hex(6)}", limit: 1, wait_ms: 0).call { :ok }
    end

    assert_empty captured
  end

  private

  def capture_log
    output = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    yield
    output.string
  ensure
    Rails.logger = original
  end

  def with_sentry_capture(captured)
    singleton = Sentry.singleton_class
    original = singleton.instance_method(:capture_message)
    singleton.define_method(:capture_message) { |message, **options| captured << [ message, options ] }
    yield
  ensure
    singleton.send(:remove_method, :capture_message) if singleton.method_defined?(:capture_message, false)
    singleton.define_method(:capture_message, original)
  end
end
