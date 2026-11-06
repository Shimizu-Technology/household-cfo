require "test_helper"

class ParticipantMessageReaderOutageTest < ActiveSupport::TestCase
  setup do
    @cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @events = []
    events = @events
    @initialized = Sentry.method(:initialized?)
    @capture = Sentry.method(:capture_message)
    Sentry.define_singleton_method(:initialized?) { true }
    Sentry.define_singleton_method(:capture_message) { |message, **options| events << [ message, options ] }
    @connection = OpenRouterConnection.method(:start)
  end
  teardown do
    Rails.cache = @cache
    Sentry.define_singleton_method(:initialized?, @initialized)
    Sentry.define_singleton_method(:capture_message, @capture)
    OpenRouterConnection.define_singleton_method(:start, @connection)
  end

  test "HTTP failures keep status in logs and one outage emits one Sentry signal" do
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    Rails.logger.broadcast_to(logger)
    [ 400, 404, 500, 500 ].each do |status|
      response = Net::HTTPResponse::CODE_TO_OBJ.fetch(status.to_s).new("1.1", status.to_s, "Provider error")
      response.body = "{}"
      response.instance_variable_set(:@read, true)
      requester = Object.new
      requester.define_singleton_method(:request) { |_| response }
      OpenRouterConnection.define_singleton_method(:start) { |*_args, **_options, &block| block.call(requester) }
      refute HouseholdFinance::ParticipantMessageReader.call(message: "saved 20 today", api_key: "test-only").available
      assert_includes output.string, "\"status\":#{status}"
    end
    assert_equal 1, @events.length
    assert_equal 400, @events.first.last.fetch(:tags).fetch(:ai_status)
  ensure
    Rails.logger.stop_broadcasting_to(logger) if logger
  end

  test "an account outage through the shared connection still emits only one reader signal" do
    original = Net::HTTP.method(:start)
    response = Net::HTTPUnauthorized.new("1.1", "401", "Unauthorized")
    response.body = "{}"
    response.instance_variable_set(:@read, true)
    requester = Object.new
    requester.define_singleton_method(:request) { |_| response }
    Net::HTTP.define_singleton_method(:start) { |*_args, **_kwargs, &block| block.call(requester) }
    2.times { HouseholdFinance::ParticipantMessageReader.call(message: "saved 20 today", api_key: "test-only") }
    assert_equal 1, @events.length
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
  end

  test "unusable JSON reports a throttled failure while invalid items do not" do
    2.times { HouseholdFinance::ParticipantMessageReader.call(message: "saved 20 today", transport: ->(_) { "{bad" }) }
    assert_equal 1, @events.length
    assert_match(/JSON/, @events.first.first)
    Rails.cache.clear
    @events.clear
    result=HouseholdFinance::ParticipantMessageReader.call(message: "my mom died", transport: ->(_) { { care: "grief", facts: [ { bad: true } ] }.to_json })
    assert result.available
    assert_equal "grief", result.care
    assert_empty @events
  end
end
