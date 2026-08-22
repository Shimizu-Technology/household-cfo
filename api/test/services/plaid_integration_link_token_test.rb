require "test_helper"
require "ostruct"

class PlaidIntegrationLinkTokenTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(clerk_id: "link_#{SecureRandom.hex(6)}", email: "plaid-link@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "adds the configured OAuth redirect URI to initial Link tokens" do
    with_environment("PLAID_REDIRECT_URI" => "http://localhost:5173/") do
      request = capture_request

      assert_equal "http://localhost:5173/", request.redirect_uri
      assert_equal [ Plaid::Products::TRANSACTIONS ], request.products
      assert_equal 90, request.transactions.days_requested
    end
  end

  test "adds the configured OAuth redirect URI to update-mode Link tokens" do
    item = @household.plaid_items.create!(
      connected_by_user: @user,
      plaid_item_id: "update-item",
      access_token: "update-secret",
      institution_name: "Sandbox Bank",
      environment: "sandbox",
      consented_at: Time.current,
      consent_policy_version: "test"
    )

    with_environment("PLAID_REDIRECT_URI" => "http://localhost:5173/") do
      request = capture_request(item)

      assert_equal "http://localhost:5173/", request.redirect_uri
      assert_equal "update-secret", request.access_token
      assert_nil request.products
    end
  end

  test "omits a redirect URI when none is configured" do
    request = capture_request

    assert_nil request.redirect_uri
  end

  test "uses the published Link customization when configured" do
    with_environment("PLAID_LINK_CUSTOMIZATION_NAME" => "household-cfo-production") do
      request = capture_request

      assert_equal "household-cfo-production", request.link_customization_name
    end
  end

  private

  def capture_request(item = nil)
    captured = nil
    fake = Object.new
    fake.define_singleton_method(:link_token_create) do |request|
      captured = request
      OpenStruct.new(link_token: "link-sandbox-test")
    end

    with_client(fake) do
      PlaidIntegration::LinkToken.new(household: @household, user: @user, plaid_item: item).call
    end
    captured
  end

  def with_client(fake)
    singleton = class << PlaidIntegration::Client; self; end
    original = PlaidIntegration::Client.method(:safely)
    singleton.define_method(:safely) { |&block| block.call(fake) }
    yield
  ensure
    singleton.define_method(:safely, original)
  end

  def with_environment(values)
    previous = values.to_h { |key, _value| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
