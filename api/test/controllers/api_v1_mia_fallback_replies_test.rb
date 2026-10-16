require "test_helper"

# QA (2026-10-16): about one Mia reply in five was a canned fallback that quoted
# the participant's message back, including a 7,000-character message, and the
# same canned text sat under the 988 check for hopeless language. Provider
# outages produced the same text with no hint that anything was wrong.
class ApiV1MiaFallbackRepliesTest < ActionDispatch::IntegrationTest
  setup do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time
    @user, @household = HouseholdFinance::MiaEvalHousehold.create!
  end

  teardown { travel_back }

  test "a provider outage says Mia cannot answer right now and never echoes the question" do
    message = "is 4200 enough for a family of 5 on guam"
    content = with_provider_down { post_message(message) }

    assert_response :created
    assert content.start_with?(Mia::FallbackReply::PROVIDER_UNAVAILABLE), content
    assert_includes content, "Nothing in your household records changed."
    refute_includes content.downcase, message
    refute_includes content, "protecting the household baseline"
  end

  test "a reply rejected by the guardrail answers from approved numbers instead of echoing" do
    message = "ok last thing what should i focus on this week"
    content = with_model_reply("Put $1,234 toward runway this week.") { post_message(message) }

    assert_response :created
    readiness = HouseholdFinance::SnapshotBuilder.new(@household).call.fetch(:readiness_label)[/\A(Red|Yellow|Green)/, 1]
    assert_includes content, "What I can tell you is that your readiness is #{readiness}"
    refute_includes content, "$1,234"
    refute_includes content.downcase, message
    refute_includes content, "try again in a few minutes"
  end

  test "a 7,000 character message is never quoted back in the reply" do
    message = ("my husband got his hours cut at the hotel in tumon and now we only getting like 3800 a month, " * 75).strip
    content = with_provider_down { post_message(message) }

    assert_response :created
    assert_operator content.length, :<, 600
    refute_includes content, "hours cut at the hotel"
  end

  test "hopeless language gets kind money help under one safety check" do
    message = "whats the point, we're never gonna get out of this debt. i feel hopeless"
    content = with_provider_down { post_message(message) }

    assert_response :created
    assert_equal 1, content.scan("988").length, content
    assert_includes content, Mia::CrisisBoundary::WELLBEING_CHECK
    refute_includes content.downcase, "i feel hopeless"
    refute_includes content, "protecting the household baseline"
    answer = content.sub(Mia::CrisisBoundary::WELLBEING_CHECK, "").sub(Mia::CrisisBoundary::WELLBEING_OPENING, "").strip
    assert_operator answer.length, :>, 60, content
    assert_operator content.split(Mia::ResponseShapePolicy::SENTENCE_BOUNDARY).count(&:present?), :<=, 6, content
  end

  test "thanks is answered without a model call" do
    calls = 0
    content = with_model_reply("You're welcome! Put $1,234 toward runway.", on_call: -> { calls += 1 }) do
      post_message("thanks mia si yu'os ma'ase")
    end

    assert_response :created
    assert_equal HouseholdFinance::ConversationFollowupResolver::ACKNOWLEDGMENT_ANSWER, content
    assert_equal 0, calls, "a thank-you needs neither the intent model nor the reply model"
  end

  test "pause personalization and forget point to the memory controls" do
    pause = post_message("pause personalization")
    assert_response :created
    assert_includes pause, "My Profile → What Mia remembers"
    assert_includes pause, "Pause personalization"

    forget = post_message("forget that our income is 9000")
    assert_response :created
    assert_includes forget, "choose Forget on that item"
    assert_equal 0, @household.household_memories.count
  end

  test "forget and delete only become memory help when the whole message is a memory request" do
    forget_copy = "choose Forget on that item"
    [
      "forget that my rent went up, how much did I spend?",
      "delete that i spent $40 at Payless",
      "Forget that… we are out of food and we have no money until friday"
    ].each do |message|
      content = post_message(message)
      assert_response :created
      refute_includes content, forget_copy, message
    end
    assert_includes post_message("Forget that we are out of food and we have no money until friday"), "food pantry"
    assert_includes post_message("forget that our income is actually 9000 a month"), forget_copy
  end

  private

  def post_message(content)
    post "/api/v1/mia/messages", params: { message: content, year: 2026, month: 7 },
      headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
    response.parsed_body.dig("assistant_message", "content").to_s
  end

  # Every OpenRouter call fails the way it did when credits ran out: HTTP 402
  # with an empty body.
  def with_provider_down(&block)
    with_openrouter(-> { response_double(Net::HTTPPaymentRequired, "402", "") }, &block)
  end

  # Every OpenRouter call returns the same text; the intent resolver cannot
  # parse it, so the turn reaches the general reply path.
  def with_model_reply(text, on_call: nil, &block)
    body = JSON.generate(id: "gen-test", model: "anthropic/claude-sonnet-5.5", choices: [ { message: { content: text } } ])
    with_openrouter(lambda {
      on_call&.call
      response_double(Net::HTTPOK, "200", body)
    }, &block)
  end

  def with_openrouter(responder)
    previous_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = "test-key"
    singleton = OpenRouterConnection.singleton_class
    original = singleton.instance_method(:start)
    singleton.define_method(:start) do |*_args, **_options, &block|
      http = Object.new
      http.define_singleton_method(:request) { |_request| responder.call }
      block.call(http)
    end
    yield
  ensure
    singleton.send(:remove_method, :start)
    singleton.define_method(:start, original)
    previous_key ? ENV["OPENROUTER_API_KEY"] = previous_key : ENV.delete("OPENROUTER_API_KEY")
  end

  def response_double(klass, code, body)
    klass.new("1.1", code, "status").tap do |response|
      response.instance_variable_set(:@read, true)
      response.body = body
    end
  end
end
