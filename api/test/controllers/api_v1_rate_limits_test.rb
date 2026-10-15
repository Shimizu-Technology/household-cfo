require "test_helper"

class ApiV1RateLimitsTest < ActionDispatch::IntegrationTest
  CALM_MESSAGE = "You're going a little fast. Give it a minute and try again."

  # 30 seconds into a minute, 10-minute, and hour window, so Retry-After is the
  # remaining part of the window, not the whole window.
  NOW = Time.utc(2026, 10, 15, 4, 0, 30)

  setup do
    travel_to NOW
    @user = create_user("rate-limit-#{SecureRandom.hex(4)}@example.com")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  test "mia messages allow twenty per minute and then answer with a calm 429" do
    with_rate_limit_store do
      20.times do
        post_mia_message("")
        assert_response :unprocessable_entity
      end

      post_mia_message("")

      assert_rate_limited(retry_after: 30)
    end
  end

  test "crisis messages are never throttled or counted" do
    with_rate_limit_store do |store|
      exhaust(store, "api/v1/mia_messages", "mia-minute", 20)
      exhaust(store, "api/v1/mia_messages", "mia-hour", 200)
      post_mia_message("")
      assert_rate_limited(retry_after: 30)
      counts = [ "mia-minute", "mia-hour" ].map { |name| store.read(rate_limit_key("api/v1/mia_messages", name), raw: true) }
      assert_equal [ 21, 200 ], counts

      post_mia_message("I want to end it all.")

      assert_response :created
      assert_includes response.parsed_body.dig("assistant_message", "content"), "988"
      assert_equal counts, [ "mia-minute", "mia-hour" ].map { |name| store.read(rate_limit_key("api/v1/mia_messages", name), raw: true) }
    end
  end

  test "a new window opens when the old one ends" do
    with_rate_limit_store do |store|
      exhaust(store, "api/v1/mia_messages", "mia-minute", 20)
      post_mia_message("")
      assert_rate_limited(retry_after: 30)

      travel 30.seconds
      post_mia_message("")

      assert_response :unprocessable_entity
    end
  end

  test "mia messages also cap the hour" do
    with_rate_limit_store do |store|
      exhaust(store, "api/v1/mia_messages", "mia-hour", 199)
      post_mia_message("")
      assert_response :unprocessable_entity

      post_mia_message("")

      assert_rate_limited(retry_after: 3570)
    end
  end

  test "limits are counted per participant" do
    other = create_user("rate-limit-other-#{SecureRandom.hex(4)}@example.com")
    other_household = HouseholdFinance::WorkspaceResolver.new(other).household

    with_rate_limit_store do |store|
      exhaust(store, "api/v1/mia_messages", "mia-minute", 20)
      post_mia_message("")
      assert_rate_limited(retry_after: 30)

      post "/api/v1/mia/messages", params: { message: "" }, headers: auth_headers(other, other_household), as: :json

      assert_response :unprocessable_entity
    end
  end

  test "voice transcription allows ten per minute" do
    with_rate_limit_store do |store|
      exhaust(store, "api/v1/mia_transcriptions", "transcription", 9)
      post "/api/v1/mia/transcriptions", headers: auth_headers(@user)
      assert_response :unprocessable_entity

      post "/api/v1/mia/transcriptions", headers: auth_headers(@user)

      assert_rate_limited(retry_after: 30)
    end
  end

  test "upload endpoints each allow twenty per ten minutes and reprocessing allows ten" do
    with_rate_limit_store do |store|
      {
        "/api/v1/document_imports" => [ "upload-create", 20 ],
        "/api/v1/document_imports/presign" => [ "upload-presign", 20 ],
        "/api/v1/document_imports/complete" => [ "upload-complete", 20 ],
        "/api/v1/document_imports/0/reprocess" => [ "reprocess", 10 ]
      }.each do |path, (name, limit)|
        assert_limit(store, path, "api/v1/document_imports", name, limit, retry_after: 570)
      end
    end
  end

  test "bank connection endpoints each allow ten per ten minutes" do
    with_rate_limit_store do |store|
      {
        "/api/v1/plaid/items/link_token" => "link-token",
        "/api/v1/plaid/items/0/update_link_token" => "update-link-token",
        "/api/v1/plaid/items/exchange" => "exchange",
        "/api/v1/plaid/items/0/sync" => "sync"
      }.each do |path, name|
        assert_limit(store, path, "api/v1/plaid/items", name, 10, retry_after: 570)
      end
    end
  end

  test "reads are not throttled" do
    with_rate_limit_store do |store|
      exhaust(store, "api/v1/mia_messages", "mia-minute", 50)

      get "/api/v1/mia/messages", headers: auth_headers(@user)

      assert_response :success
    end
  end

  private

  def with_rate_limit_store
    store = ActiveSupport::Cache::MemoryStore.new
    # The test environment uses NullStore; exercise the framework limiter with
    # a real cache increment, as production's SolidCache does.
    limiter_store = Api::V1::BaseController.cache_store
    singleton = limiter_store.singleton_class
    singleton.define_method(:increment) { |*args, **options| store.increment(*args, **options) }
    yield store
  ensure
    singleton.send(:remove_method, :increment) if singleton&.method_defined?(:increment, false)
  end

  # Pre-count all but the last allowed request so each boundary is exercised
  # without dozens of slow requests: one more is allowed, the next is refused.
  def exhaust(store, controller_path, name, count)
    store.increment(rate_limit_key(controller_path, name), count, expires_in: 1.hour)
  end

  WINDOWS = { "mia-minute" => 60, "transcription" => 60, "mia-hour" => 3600 }.freeze

  def rate_limit_key(controller_path, name)
    window = WINDOWS.fetch(name, 600)
    "rate-limit:#{controller_path}:#{name}:#{@user.id}:#{Time.current.to_i / window}"
  end

  def assert_limit(store, path, controller_path, name, limit, retry_after:)
    exhaust(store, controller_path, name, limit - 1)
    post path, params: {}, headers: auth_headers(@user, @household), as: :json
    refute_equal 429, response.status, "#{path} refused request #{limit}"

    post path, params: {}, headers: auth_headers(@user, @household), as: :json

    assert_rate_limited(retry_after: retry_after)
  end

  def post_mia_message(message)
    post "/api/v1/mia/messages", params: { message: message }, headers: auth_headers(@user, @household), as: :json
  end

  def assert_rate_limited(retry_after:)
    assert_response :too_many_requests
    assert_equal retry_after.to_s, response.headers["Retry-After"]
    assert_equal(
      { "error" => CALM_MESSAGE, "errors" => [ CALM_MESSAGE ], "code" => "rate_limited", "retry_after_sec" => retry_after },
      response.parsed_body
    )
  end

  def create_user(email)
    User.create!(clerk_id: "clerk_#{SecureRandom.hex(6)}", email: email, role: "participant", invitation_status: "accepted")
  end

  def auth_headers(user, household = nil)
    headers = { "Authorization" => "Bearer test_token_#{user.id}" }
    headers["X-Financial-Generation"] = household.reload.financial_generation.to_s if household
    headers
  end
end
