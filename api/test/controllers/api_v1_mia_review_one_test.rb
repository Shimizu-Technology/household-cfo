# frozen_string_literal: true

require "test_helper"

class ApiV1MiaReviewOneTest < ActionDispatch::IntegrationTest
  setup do
    travel_to HouseholdFinance::MiaEvalHousehold.eval_time
    @user, @household = HouseholdFinance::MiaEvalHousehold.create!
  end
  teardown { travel_back }

  test "purchase narrator receives real prior participant and assistant turns" do
    seen = []
    original = HouseholdFinance::MiaNarrator.singleton_class.instance_method(:new)
    HouseholdFinance::MiaNarrator.singleton_class.define_method(:new) do |**args|
      seen << args
      original.bind_call(self, **args.merge(api_key: ""))
    end
    post_message("I cannot pay rent this month.")
    post_message("Should I buy a $300 stroller?")
    purchase = seen.reverse.find { |args| args.dig(:answer_packet, :kind) == "purchase_scenario" }
    assert purchase, seen.map { |args| args.dig(:answer_packet, :kind) }.inspect
    assert purchase[:history].any? { |turn| (turn[:content] || turn["content"]).include?("cannot pay rent") }
    assert purchase[:history].any? { |turn| (turn[:role] || turn["role"]).to_s == "assistant" }
  ensure
    HouseholdFinance::MiaNarrator.singleton_class.define_method(:new, original)
  end

  test "income plus purchase while setup incomplete gives the guided setup prompt without a write" do
    @user = User.create!(clerk_id: "setup-review-one", email: "setup-review-one@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    assert_no_difference [ -> { @household.mia_action_drafts.count }, -> { @household.transaction_drafts.count }, -> { @household.income_sources.count } ] do
      post_message("I make $5,200 a month now. Should I buy a $600 phone?")
    end
    reply = response.parsed_body.dig("assistant_message", "content")
    assert_includes reply, "household details"
    refute_includes reply, "Open Budget"
  end

  private

  def post_message(message)
    post "/api/v1/mia/messages", params: { message: message, year: 2026, month: 7 }, headers: {
      "Authorization" => "Bearer test_token:#{@user.clerk_id}:#{@user.email}:Mel:Test"
    }, as: :json
    assert_response :created
  end
end
