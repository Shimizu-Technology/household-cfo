require "test_helper"

class HouseholdFinanceMiaProviderEndpointTest < ActiveSupport::TestCase
  test "uses the official OpenRouter endpoint by default" do
    with_environment("OPENROUTER_MIA_URL" => nil) do
      assert_equal HouseholdFinance::MiaProviderEndpoint::DEFAULT_URL, HouseholdFinance::MiaProviderEndpoint.uri.to_s
    end
  end

  test "allows an explicit local HTTP endpoint outside production" do
    with_environment("OPENROUTER_MIA_URL" => "http://127.0.0.1:4567/chat") do
      assert_equal "http://127.0.0.1:4567/chat", HouseholdFinance::MiaProviderEndpoint.uri.to_s
    end
  end

  private

  def with_environment(values)
    previous = values.to_h { |key, _value| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
