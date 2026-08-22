require "test_helper"

class PlaidIntegrationConfigurationTest < ActiveSupport::TestCase
  test "sandbox requires credentials and the separate encryption key" do
    with_environment(valid_credentials.merge("PLAID_ENV" => "sandbox")) do
      assert PlaidIntegration::Configuration.validate!
      assert PlaidIntegration::Configuration.configured?
    end
  end

  test "production requires the webhook and OAuth redirect to use HTTPS" do
    with_environment(valid_credentials.merge(
      "PLAID_ENV" => "production",
      "PLAID_WEBHOOK_URL" => "http://example.com/api/plaid/webhook",
      "PLAID_REDIRECT_URI" => "https://app.example.com/"
    )) do
      error = assert_raises(PlaidIntegration::Error) { PlaidIntegration::Configuration.validate! }
      assert_includes error.message, "PLAID_WEBHOOK_URL"
      refute PlaidIntegration::Configuration.configured?
    end
  end

  test "production requires the exact webhook endpoint path" do
    with_environment(valid_production_environment.merge("PLAID_WEBHOOK_URL" => "https://api.example.com/wrong")) do
      error = assert_raises(PlaidIntegration::Error) { PlaidIntegration::Configuration.validate! }
      assert_includes error.message, "/api/plaid/webhook"
    end
  end

  test "production validates with complete HTTPS configuration" do
    with_environment(valid_production_environment) do
      assert PlaidIntegration::Configuration.validate!
      assert PlaidIntegration::Configuration.configured?
    end
  end

  private

  def valid_credentials
    {
      "PLAID_CLIENT_ID" => "client-id",
      "PLAID_SECRET" => "production-secret",
      "PLAID_DATA_ENCRYPTION_KEY" => "encryption-key"
    }
  end

  def valid_production_environment
    valid_credentials.merge(
      "PLAID_ENV" => "production",
      "PLAID_WEBHOOK_URL" => "https://api.example.com/api/plaid/webhook",
      "PLAID_REDIRECT_URI" => "https://app.example.com/"
    )
  end

  def with_environment(values)
    previous = values.to_h { |key, _value| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
