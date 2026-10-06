require "test_helper"

class EnterpriseClientTest < ActiveSupport::TestCase
  test "events request uses official repeated filters ascending order and bounded timeout" do
    original = Net::HTTP.method(:start)
    previous_key = ENV["WORKOS_API_KEY"]
    ENV["WORKOS_API_KEY"] = "test_provider_key"
    captured = nil
    options = nil
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.define_singleton_method(:body) { '{"data":[]}' }
    transport = Object.new
    transport.define_singleton_method(:request) { |request| captured = request; response }
    Net::HTTP.define_singleton_method(:start) do |host, port, **settings, &block|
      options = [ host, port, settings ]
      block.call(transport)
    end
    Enterprise::Client.new.events(after: "event_saved")
    query = URI.decode_www_form(captured.uri.query)
    assert_equal Enterprise::Client::EVENTS, query.select { |key, _value| key == "events" }.map(&:last)
    refute query.any? { |key, _value| key == "events[]" }
    assert_includes query, [ "order", "asc" ]
    assert_includes query, [ "after", "event_saved" ]
    assert_equal [ "api.workos.com", 443 ], options.first(2)
    assert_equal 3, options.last[:open_timeout]
    assert_equal 5, options.last[:read_timeout]
  ensure
    Net::HTTP.define_singleton_method(:start, original) if original
    ENV["WORKOS_API_KEY"] = previous_key
  end
end
