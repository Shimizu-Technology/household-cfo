require "test_helper"
require_relative "../support/savings_challenge_test_support"

# The participant's screens decide "savings challenge" from the sealed release.
# Mia, chat history and review drafts must decide it the same way, whether or
# not the challenge is open yet.
class ApiV1ChallengeProgramModeTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport

  setup do
    setup_savings_context
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12)
    with_savings_runtime { }
    @ordinary = Cohort.create!(name: "Ordinary household program", status: "active", created_by_user: @savings_owner)
    @ordinary_membership = CohortMembership.create!(cohort: @ordinary, user: @savings_user, role: "participant")
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end

  teardown do
    ENV["OPENROUTER_API_KEY"] = @old_key
    travel_back
  end

  test "savings mode comes from the sealed release, open comes from the flags" do
    mode = SavingsChallenge::ProgramMode
    assert mode.savings?(user: @savings_user, membership: @savings_membership)
    assert mode.open?(@savings_cohort)
    not_open!
    assert mode.savings?(user: @savings_user, membership: @savings_membership), "sealed savings mode stays savings while closed"
    refute mode.open?(@savings_cohort)
    assert_equal @savings_cohort.id, mode.scope_cohort_id(user: @savings_user, membership: @savings_membership)
    refute mode.savings?(user: @savings_user, membership: @ordinary_membership)
    assert_nil mode.scope_cohort_id(user: @savings_user, membership: @ordinary_membership)
    refute mode.open?(nil)
    @savings_cohort.update!(savings_challenge_enabled: true, savings_challenge_release_hold: false)
    assert mode.open?(@savings_cohort)
    @savings_cohort.update!(status: "archived")
    refute mode.open?(@savings_cohort)
  end

  test "workspace says whether the challenge is open and ordinary programs never wait" do
    get "/api/v1/workspace", headers: auth(@savings_cohort)
    body = response.parsed_body.fetch("workspace", response.parsed_body)
    assert_equal "savings_challenge", body.fetch("experience_mode")
    assert_equal true, body.fetch("challenge_open")
    not_open!
    get "/api/v1/workspace", headers: auth(@savings_cohort)
    body = response.parsed_body.fetch("workspace", response.parsed_body)
    assert_equal "savings_challenge", body.fetch("experience_mode")
    assert_equal false, body.fetch("challenge_open")
    assert_equal "not_open", body.fetch("challenge_state")
    @savings_cohort.update!(savings_challenge_enabled: true, savings_challenge_release_hold: true)
    get "/api/v1/workspace", headers: auth(@savings_cohort)
    assert_equal "paused", response.parsed_body.fetch("workspace", response.parsed_body).fetch("challenge_state")
    assert_equal false, response.parsed_body.fetch("workspace", response.parsed_body).fetch("challenge_joined")
    not_open!
    get "/api/v1/workspace", headers: auth(@ordinary)
    body = response.parsed_body.fetch("workspace", response.parsed_body)
    assert_equal "household_cfo", body.fetch("experience_mode")
    assert_equal true, body.fetch("challenge_open")
    assert_equal "open", body.fetch("challenge_state")
  end

  [ true, false ].each do |open|
    test "chat history and review drafts never cross programs (#{open ? 'open' : 'not open yet'})" do
      ordinary_session = ChatSession.create!(household: @savings_household, user: @savings_user)
      ordinary_message = ordinary_session.chat_messages.create!(role: "user", content: "Ordinary household question")
      savings_session = ChatSession.create!(household: @savings_household, user: @savings_user, cohort: @savings_cohort)
      savings_message = savings_session.chat_messages.create!(role: "user", content: "Challenge question",
        cohort: @savings_cohort, cohort_release: @savings_release)
      ordinary_draft = draft_for(ordinary_message, "Ordinary review")
      savings_draft = draft_for(savings_message, "Challenge review")
      not_open! unless open

      get "/api/v1/mia/messages", headers: auth(@ordinary)
      assert_response :success
      assert_equal [ ordinary_message.id ], response.parsed_body.fetch("messages").pluck("id")
      get "/api/v1/mia/messages", headers: auth(@savings_cohort)
      assert_response :success
      assert_equal(open ? [ savings_message.id ] : [], response.parsed_body.fetch("messages").pluck("id"))

      ordinary_ids = Mia::ActionDraftScope.records(@savings_household.mia_action_drafts, user: @savings_user, membership: @ordinary_membership).pluck(:id)
      savings_ids = Mia::ActionDraftScope.records(@savings_household.mia_action_drafts, user: @savings_user, membership: @savings_membership).pluck(:id)
      assert_equal [ ordinary_draft.id ], ordinary_ids
      assert_equal [ savings_draft.id ], savings_ids
      assert_raises(Mia::ActionDraftScope::Mismatch) { Mia::ActionDraftScope.authorize!(savings_draft, user: @savings_user, membership: @ordinary_membership) }
      assert_raises(Mia::ActionDraftScope::Mismatch) { Mia::ActionDraftScope.authorize!(ordinary_draft, user: @savings_user, membership: @savings_membership) }
    end
  end

  test "when the challenge is not open Mia says so and creates nothing" do
    not_open!
    assert_no_difference [ "ChatMessage.count", "ChatSession.count", "TransactionDraft.count", "MiaActionDraft.count", "SavingsEntryDraft.count", "SavingsDailyPurchaseDraft.count" ] do
      [ "I set aside $50 from my paycheck today into my savings challenge reserve", "I spent $12.50 at Payless today on snacks" ].each_with_index do |text, index|
        post "/api/v1/mia/messages", params: { message: text, request_id: "closed-#{index}" }, headers: auth(@savings_cohort), as: :json
        assert_response :created
        assert_equal false, response.parsed_body.fetch("conversation_persisted")
        reply = response.parsed_body.dig("assistant_message", "content")
        assert_includes reply, "isn't open yet"
        assert_nil response.parsed_body["transaction_draft"]
        assert_nil response.parsed_body["mia_action_draft"]
      end
    end
  end

  test "closed challenge still validates blank and oversized messages" do
    not_open!
    post "/api/v1/mia/messages", params: { message: "   ", request_id: "closed-blank" }, headers: auth(@savings_cohort), as: :json
    assert_response :unprocessable_entity
    post "/api/v1/mia/messages", params: { message: "a" * (ChatMessage::MAX_CONTENT_LENGTH + 1), request_id: "closed-long" }, headers: auth(@savings_cohort), as: :json
    assert_response :unprocessable_entity
    refute_includes response.body, "aaaa"
  end

  test "closed challenge refuses private document uploads" do
    not_open!
    file = Tempfile.new([ "budget", ".csv" ]); file.write("Category,Amount\nIncome,4000\n"); file.rewind
    upload = Rack::Test::UploadedFile.new(file.path, "text/csv", original_filename: "budget.csv")
    assert_no_difference "FinancialDocumentImport.count" do
      post "/api/v1/document_imports", params: { file: upload, document_kind: "spreadsheet" }, headers: auth(@savings_cohort)
      assert_response :forbidden
      assert_includes response.parsed_body.fetch("errors").first, "isn't open yet"
    end
  end

  test "crisis guidance still answers while the challenge is not open" do
    not_open!
    post "/api/v1/mia/messages", params: { message: "I want to end it all.", request_id: "closed-crisis" }, headers: auth(@savings_cohort), as: :json
    assert_response :created
    assert_includes response.parsed_body.dig("assistant_message", "content"), "988"
  end

  test "default program follows a joined challenge, an explicit choice still wins" do
    resolver = ->(**options) { Mia::EffectiveCohortResolver.new(user: @savings_user, role: "participant", **options).call }
    # Not joined yet: the active ordinary program is the default, as before.
    assert_equal @ordinary.id, resolver.call.cohort_id
    enrollment = nil
    with_savings_runtime { enrollment = savings_enroll }
    assert_equal @savings_cohort.id, resolver.call.cohort_id
    assert_equal @ordinary.id, resolver.call(requested_cohort_id: @ordinary.id).cohort_id
    assert_equal @savings_cohort.id, resolver.call(requested_cohort_id: @savings_cohort.id).cohort_id
    # A second active program added later does not take the default.
    third = Cohort.create!(name: "Another active program", status: "active", created_by_user: @savings_owner, starts_on: Date.new(2026, 12, 1))
    CohortMembership.create!(cohort: third, user: @savings_user, role: "participant")
    assert_equal @savings_cohort.id, resolver.call.cohort_id
    # Withdrawn or finished challenges stop pinning the default.
    enrollment.update_columns(status: "withdrawn")
    assert_equal third.id, resolver.call.cohort_id
    enrollment.update_columns(status: "active")
    @savings_cohort.update!(status: "archived")
    assert_equal third.id, resolver.call.cohort_id
  end

  private

  def not_open!
    @savings_cohort.update!(savings_challenge_enabled: false, savings_challenge_release_hold: true)
  end

  def draft_for(message, title)
    @savings_household.mia_action_drafts.create!(requested_by_user: @savings_user, source_chat_message: message,
      draft_type: "household_setup", title: title, summary: title, year: 2026)
  end

  def auth(cohort) = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => cohort.id.to_s }
end
