require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1MiaProgramScopeTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_savings_runtime { savings_enroll; savings_plan(30_000); savings_approve(savings_draft(7500)) }
    @first_cohort = @savings_cohort
    @first_release = @savings_release
    @savings_cohort = Cohort.create!(name: "Independent synthetic program", status: "enrolling", created_by_user: @savings_owner,
      starts_on: Date.new(2026, 11, 1), savings_challenge_enabled: true, savings_challenge_release_hold: false)
    CohortMembership.create!(cohort: @savings_cohort, user: @savings_user, role: "participant")
    @savings_release = nil
    with_savings_runtime { }
    @second_cohort = @savings_cohort
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end

  teardown do
    ENV["OPENROUTER_API_KEY"] = @old_key
    travel_back
  end

  test "fresh second program never receives first program history or household Mia payload" do
    post_message(@first_cohort, "How much savings progress do I have?", "same-request")
    assert_response :created
    assert_includes response.parsed_body.dig("assistant_message", "content"), "$75.00"
    get "/api/v1/mia/messages", headers: auth(@second_cohort)
    assert_response :success
    assert_empty response.parsed_body.fetch("messages")
    get "/api/v1/workspace", headers: auth(@second_cohort)
    assert_response :success
    assert_empty response.parsed_body.dig("mia", "messages")
  end

  test "same request key is independent per program and clear preserves other program and legacy state" do
    legacy = ChatSession.create!(household: @savings_household, user: @savings_user, rolling_summary: "Legacy context")
    legacy.chat_messages.create!(role: "user", content: "Legacy household message")
    post_message(@first_cohort, "How much savings progress do I have?", "same-request")
    assert_response :created
    first_ids = response.parsed_body.values_at("user_message", "assistant_message").pluck("id")
    post_message(@second_cohort, "How much savings progress do I have?", "same-request")
    assert_response :created
    refute_includes response.body, "$75.00"
    second_ids = response.parsed_body.values_at("user_message", "assistant_message").pluck("id")
    refute_equal first_ids, second_ids
    assert_no_difference "ChatMessage.count" do
      post_message(@second_cohort, "How much savings progress do I have?", "same-request")
      assert_response :created
    end
    delete "/api/v1/mia/messages", headers: auth(@second_cohort)
    assert_response :no_content
    assert_equal 2, ChatMessage.where(id: first_ids).count
    assert_equal 0, ChatMessage.where(id: second_ids).count
    assert_equal "Legacy context", legacy.reload.rolling_summary
    assert_equal 1, legacy.chat_messages.count
    assert_equal 1, @savings_household.chat_sessions.find_by!(cohort: @first_cohort).mia_message_requests.count
  end

  test "held program cannot read clear replay or write while crisis guidance stays stateless" do
    post_message(@first_cohort, "How much savings progress do I have?", "first-request")
    assert_response :created
    @first_cohort.update!(savings_challenge_release_hold: true)
    assert_no_difference [ "ChatMessage.count", "ChatSession.count", "MiaMessageRequest.count" ] do
      get "/api/v1/mia/messages", headers: auth(@first_cohort)
      assert_response :forbidden
      delete "/api/v1/mia/messages", headers: auth(@first_cohort)
      assert_response :forbidden
      post_message(@first_cohort, "How much savings progress do I have?", "first-request")
      assert_response :forbidden
      post_message(@first_cohort, "I want to end it all.", "crisis-held")
      assert_response :created
      assert_equal false, response.parsed_body.fetch("conversation_persisted")
      assert_includes response.parsed_body.dig("assistant_message", "content"), "988"
    end
  end

  test "removed membership during narration cannot save a late response" do
    narrator = Object.new
    narrator.define_singleton_method(:supplied_content_context) { [] }
    membership = @first_cohort.cohort_memberships.find_by!(user: @savings_user)
    narrator.define_singleton_method(:call) { membership.destroy!; "Synthetic late answer" }
    assert_no_difference "ChatMessage.count" do
      with_narrator_factory(->(**_arguments) { narrator }) do
        post_message(@first_cohort, "How much savings progress do I have?", "late-request")
        assert_response :forbidden
      end
    end
    refute_includes response.body, "Synthetic late answer"
    get "/api/v1/mia/messages", headers: auth(@first_cohort)
    assert_response :unprocessable_entity
  end

  test "narrator history pagination and selected chat sharing use only the selected program" do
    post_message(@first_cohort, "Synthetic first-program private question", "first-private")
    assert_response :created
    first_message = @savings_household.chat_sessions.find_by!(cohort: @first_cohort).chat_messages.first
    captured = nil
    factory = ->(**arguments) { captured = arguments.fetch(:history); Object.new.tap { |n|
      n.define_singleton_method(:call) { "Synthetic second-program answer" }
      n.define_singleton_method(:supplied_content_context) { [] }
    } }
    with_narrator_factory(factory) do
      post_message(@second_cohort, "Synthetic second-program question", "second-private")
      assert_response :created
    end
    assert_empty captured
    get "/api/v1/mia/messages", params: { limit: 1 }, headers: auth(@second_cohort)
    assert_response :success
    assert_equal 1, response.parsed_body.fetch("older_message_count")
    before_id = response.parsed_body.fetch("oldest_message_id")
    get "/api/v1/mia/messages", params: { before_id: before_id, limit: 1 }, headers: auth(@second_cohort)
    assert_response :success
    assert_equal 0, response.parsed_body.fetch("older_message_count")
    assert_equal [ @second_cohort.id ], response.parsed_body.fetch("messages").pluck("cohort_id").uniq
    second_enrollment = nil
    with_savings_runtime { second_enrollment = savings_enroll }
    assert_raises(ActiveRecord::RecordNotFound) do
      ChallengePrivacy::RecordSelector.new(second_enrollment).resolve!(record_type: "chat_message", record_id: first_message.id)
    end
    get "/api/v1/savings_challenge/#{second_enrollment.id}/privacy/selection_candidates", params: { record_type: "chat_message" }, headers: auth(@second_cohort)
    assert_response :success
    refute_includes response.parsed_body.fetch("records").pluck("record_id"), first_message.id
  end

  test "unattributable upgrade request returns unknown without replaying financial content" do
    legacy = ChatSession.create!(household: @savings_household, user: @savings_user)
    legacy.mia_message_requests.create!(request_key: "old-unknown", request_fingerprint: "a" * 64,
      status: "completed", response_payload: { budget: { private: "Legacy secret" } })
    assert_no_difference "ChatMessage.count" do
      post_message(@second_cohort, "How much savings progress do I have?", "old-unknown")
      assert_response :conflict
      assert_equal "unknown", response.parsed_body.fetch("status")
      assert_equal "mia_request_scope_unknown", response.parsed_body.fetch("code")
      refute_includes response.body, "Legacy secret"
    end
  end

  test "ordinary household programs retain the legacy session and history contract" do
    legacy = ChatSession.create!(household: @savings_household, user: @savings_user)
    message = legacy.chat_messages.create!(role: "user", content: "Legacy household history")
    ordinary = Cohort.create!(name: "Legacy household program", status: "active", created_by_user: @savings_owner)
    CohortMembership.create!(cohort: ordinary, user: @savings_user, role: "participant")
    get "/api/v1/mia/messages", headers: auth(ordinary)
    assert_response :success
    assert_equal [ message.id ], response.parsed_body.fetch("messages").pluck("id")
    assert_nil legacy.reload.cohort_id
    assert_equal legacy, Mia::ChatSessionScope.new(household: @savings_household, user: @savings_user,
      membership: ordinary.cohort_memberships.find_by!(user: @savings_user)).find
  end

  private

  def with_narrator_factory(factory)
    original = SavingsChallenge::Narrator.method(:new)
    SavingsChallenge::Narrator.define_singleton_method(:new, &factory)
    yield
  ensure
    SavingsChallenge::Narrator.define_singleton_method(:new, original)
  end

  def auth(cohort) = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => cohort.id.to_s }
  def post_message(cohort, message, key)
    post "/api/v1/mia/messages", params: { message: message, request_id: key }, headers: auth(cohort), as: :json
  end
end
