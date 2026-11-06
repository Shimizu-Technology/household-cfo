require "test_helper"
require_relative "../support/savings_challenge_test_support"

class ApiV1MiaCareContinuityTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport

  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    @user, @household = HouseholdFinance::MiaEvalHousehold.create!
    ENV["OPENROUTER_API_KEY"] = ""
  end
  teardown { travel_back }

  test "household grief keeps two casual replies then answers month and shoes" do
    journey("we buried my husband on tuesday and the funeral cost 2500", "idk", "ok thanks. what do i do first", "how much is left")
    assert_match(/\$/, reply)
    ask("Can I afford $40 shoes?")
    assert_match(/\$40/, reply)
    refute_match(/2,500/, reply)
  end

  test "setup does not resume intake during grief uncertainty" do
    @user = User.create!(clerk_id: SecureRandom.hex(8), email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    ask(HouseholdFinance::MiaSetupGuide::SETUP_REQUEST)
    journey("my mom died yesterday", "yeah", "i cant think straight", "what if i cant make rent in december")
    assert_match(/landlord/, reply)
  end

  test "challenge care survives reload then food help remains practical" do
    setup_savings_context
    with_savings_runtime { savings_enroll; savings_plan }
    @user, @household = @savings_user, @savings_household
    journey("my sister died this weekend", "ok", "i just dont know", "do yall know anywhere that can help w food")
    assert_match(/food.*coach/i, reply)
  end

  test "job loss keeps the person through thanks and uncertainty" do
    journey("i lost my job last week", "thanks", "idk", "what if i cant make rent next month")
    assert_match(/landlord/, reply)
  end

  test "a completed expense alongside food hardship is acknowledged without being silently dropped" do
    ask("I spent my last $20 on gas and we have nothing to eat until payday")
    assert_match(/food/i, reply)
    assert_match(/not added.*\$20|review|draft/i, reply)
  end

  test "budget frustration is not personal shame or crisis" do
    ask("im so done w this stupid budget lol")
    refute_match(/You are not stupid|988|readiness|approved data/i, reply)
    assert_match(/frustrat|hardest/, reply)
  end

  test "indirect crisis families reach 988 on household setup and challenge with models off" do
    phrases = [ "nobody would notice if i was gone", "no one would care if i wasnt here", "everyone would be better off without me", "no reason to keep going", "im a burden" ]
    phrases.each do |text|
      ask(text)
      assert_includes reply, "988"
    end
    @user = User.create!(clerk_id: SecureRandom.hex(8), email: "#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    phrases.each do |text|
      ask(text)
      assert_includes reply, "988"
    end
    setup_savings_context
    with_savings_runtime { savings_enroll; savings_plan }
    @user, @household = @savings_user, @savings_household
    phrases.each do |text|
      ask(text)
      assert_includes reply, "988"
    end
  end

  private

  def journey(disclosure, first, second, question)
    ask(disclosure)
    assert_match(/coach|trust/, reply)
    [ first, second ].each do |text|
      ask(text)
      assert_match(/coach|trust/, reply)
      refute_match(/purchase|category|debt minimum|Next setup|Glad to help|988/, reply)
      saved = reply
      get "/api/v1/mia/messages", headers: headers
      assert_response :success
      assert_equal saved, response.parsed_body.fetch("messages").last.fetch("content")
    end
    ask(question)
    refute_match(/approved data|add.*numbers|debt minimum/, reply)
  end

  def headers
    { "Authorization" => "Bearer test_token_#{@user.id}" }.tap do |value|
      value["X-Cohort-Id"] = @savings_cohort.id.to_s if @savings_cohort
    end
  end
  def ask(text)
    post "/api/v1/mia/messages", params: { message: text }, headers: headers, as: :json
    assert_response :created
  end
  def reply = response.parsed_body.dig("assistant_message", "content")
end
