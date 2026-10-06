require "test_helper"
require_relative "../support/savings_debt_test_support"

class ApiV1FinancialRestartsControllerTest < ActionDispatch::IntegrationTest
  include SavingsDebtTestSupport
  setup do
    setup_savings_context
    @user, @household = @savings_user, @savings_household
  end

  test "ordinary Mia recognizes complete reset and Everything continuations without provider or writes" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    assert_no_difference [ "Debt.count", "IncomeSource.count", "FinancialRestartReview.count" ] do
      [ "So these aren't my actual numbers - are you able to reset it all and we can start from scratch?", "Everything", "All the information that I have" ].each_with_index do |message, index|
        post "/api/v1/mia/messages", params: { message: message, request_id: "restart-loop-#{index}" }, headers: auth, as: :json
        assert_response :created
        assert_equal "review_available", response.parsed_body.dig("financial_restart", "state")
        assert_equal true, response.parsed_body.dig("assistant_message", "financial_restart", "available")
        assert_includes response.parsed_body.dig("assistant_message", "content"), "Nothing changes until"
        refute_includes response.parsed_body.dig("assistant_message", "content"), "What specific"
      end
    end
    get "/api/v1/mia/messages", headers: auth
    assert_response :success
    assert response.body.include?("review_available")
  end

  test "BOG participant reset routing remains unavailable and preserves challenge progress and optional terms" do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_evidence_operations do
        savings_enroll
        savings_plan
        entry = savings_approve(savings_draft(20_000))
        source, document = evidence_source
        evidence_attach(entry, [ evidence_proof(source, amount: 15_000) ])
        terms = debt_approve(debt_stage)
        before = savings_projection.slice(:reported_cents, :evidence_supported_cents)
        3.times do |index|
          message = [ "Please reset all my information and start over", "Everything", "All the information that I have" ][index]
          post "/api/v1/mia/messages", params: { message: message, request_id: "bog-restart-#{index}" }, headers: auth, as: :json
          assert_response :created
          assert_equal false, response.parsed_body.dig("financial_restart", "available")
          assert_includes response.parsed_body.dig("assistant_message", "content"), "correct your income"
        end
        assert_no_difference "FinancialRestartReview.count" do
          post "/api/v1/financial_restart/preview", headers: auth, as: :json
          assert_response :forbidden
          assert_equal "financial_restart_admin_required", response.parsed_body["code"]
        end
        assert_equal 0, @household.reload.financial_generation
        assert_equal before, savings_projection.slice(:reported_cents, :evidence_supported_cents)
        assert_equal 15_000, savings_projection[:evidence_supported_cents]
        assert_equal terms.terms, terms.reload.terms
        assert_equal document.id, FinancialDocumentImport.find(document.id).id
        assert_equal source.id, SourceReviewVersion.find(source.id).id
      end
    end
  end

  test "stale financial writes reject but privacy controls remain available and apply status is exact" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    post "/api/v1/financial_restart/preview", headers: auth, as: :json
    id = response.parsed_body.dig("financial_restart", "review", "id")
    post "/api/v1/financial_restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :success
    assert_equal 1, @household.reload.financial_generation
    post "/api/v1/income_sources", params: { income_source: { label: "Stale", amount: 200, source_type: "job", cadence: "monthly" } }, headers: auth, as: :json
    assert_response :conflict
    assert_equal "financial_generation_stale", response.parsed_body["code"]
    post "/api/v1/income_sources", params: { income_source: { label: "Fresh", amount: 200, source_type: "job", cadence: "monthly" } }, headers: auth.merge("X-Financial-Generation" => "1"), as: :json
    assert_response :created
    get "/api/v1/financial_restart/status", params: { review_id: id }, headers: auth
    assert_response :success
    assert_equal id, response.parsed_body.dig("financial_restart", "latest_review", "id")
    assert_equal "applied", response.parsed_body.dig("financial_restart", "latest_review", "status")
    post "/api/v1/financial_restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :success
    assert_equal 1, @household.reload.income_sources.count
    assert_equal 1, @household.financial_generation
  end

  test "prior bank OAuth callbacks and saved memory confirmations require the current financial picture" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
    preview = flow.preview
    flow.apply(review_id: preview[:review][:id], confirmation: "START OVER")
    [ "/api/v1/plaid/items/exchange", "/api/v1/plaid/items/link_token", "/api/v1/plaid/transactions/stage" ].each do |path|
      post path, params: {}, headers: auth.merge("X-Financial-Generation" => "0"), as: :json
      assert_response :conflict
      assert_equal "financial_generation_stale", response.parsed_body["code"]
    end
    post "/api/v1/household_memories", params: { household_memory: { display_value: "Old fake balance", category: "goal" } }, headers: auth.merge("X-Financial-Generation" => "0"), as: :json
    assert_response :conflict
  end

  test "workspace and budget reads crossing a restart discard mixed payloads and expose fresh generation" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    [ [ :workspace, "/api/v1/workspace" ], [ :budget, "/api/v1/budget" ] ].each do |method_name, path|
      flow = HouseholdFinance::FinancialRestart::Flow.new(@household.reload, user: @user)
      preview = flow.preview
      expected = @household.financial_generation + 1
      original = HouseholdFinance::DataPresenter.instance_method(method_name)
      restart = lambda { flow.apply(review_id: preview[:review][:id], confirmation: "START OVER") }
      HouseholdFinance::DataPresenter.define_method(method_name) do
        restart.call
        original.bind_call(self)
      end
      begin
        get path, headers: auth.merge("Origin" => "https://householdcfomethod.com")
        assert_response :conflict
        assert_equal "financial_generation_stale", response.parsed_body["code"]
        assert_equal expected, response.parsed_body["financial_generation"]
        assert_equal expected.to_s, response.headers["X-Financial-Generation"]
        assert_includes response.headers["Access-Control-Expose-Headers"], "X-Financial-Generation"
        assert_nil response.parsed_body["workspace"]
        assert_nil response.parsed_body["budget"]
      ensure
        HouseholdFinance::DataPresenter.define_method(method_name, original)
      end
    end
  end

  test "a preview captured before a restart cannot silently review the next financial picture" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
    first = flow.preview
    FinancialPicture.set(household_id: @household.id, generation: 0) do
      flow.apply(review_id: first[:review][:id], confirmation: "START OVER")
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { flow.preview }
    end
    post "/api/v1/financial_restart/preview", headers: auth.merge("X-Financial-Generation" => "0"), as: :json
    assert_response :conflict
    assert_equal "financial_generation_stale", response.parsed_body["code"]
  end

  test "clearing retained conversations preserves old reviews without leaving foreign-key blockers" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    session = @household.chat_sessions.create!(user: @user)
    user_message = session.chat_messages.create!(role: "user", content: "Fake income change")
    assistant_message = session.chat_messages.create!(role: "assistant", content: "Fake review")
    draft = @household.mia_action_drafts.create!(requested_by_user: @user, source_chat_message: user_message,
      assistant_chat_message: assistant_message, draft_type: "household_setup", title: "Fake review", summary: "Retained audit", year: 2026)
    flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
    preview = flow.preview
    flow.apply(review_id: preview[:review][:id], confirmation: "START OVER")
    delete "/api/v1/mia/messages", headers: auth
    assert_response :no_content
    assert_nil draft.reload.source_chat_message_id
    assert_nil draft.assistant_chat_message_id
    assert_equal 0, draft.financial_generation
    assert_equal @user.id, draft.metadata.dig("review_program_scope", "user_id")
    assert_empty @household.reload.mia_action_drafts
    assert_empty session.reload.chat_messages
  end

  test "a stale financial epoch does not block independent crisis guidance" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
    preview = flow.preview
    flow.apply(review_id: preview[:review][:id], confirmation: "START OVER")
    post "/api/v1/mia/messages", params: { message: "I want to end it all.", request_id: "crisis-after-restart" }, headers: auth.merge("X-Financial-Generation" => "0"), as: :json
    assert_response :created
    assert_includes response.parsed_body.dig("assistant_message", "content"), "911"
    assert_empty @household.reload.income_sources
  end

  test "an admin owner can restart their own ordinary household" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    @user.update!(role: "admin")
    post "/api/v1/financial_restart/preview", headers: auth, as: :json
    assert_response :created
    id = response.parsed_body.dig("financial_restart", "review", "id")
    assert_equal @household.name, response.parsed_body.dig("financial_restart", "review", "household_name")
    assert_equal @household.name, response.parsed_body.dig("financial_restart", "household_name")
    post "/api/v1/financial_restart/apply", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
    assert_response :success
    assert_equal 1, @household.reload.financial_generation
  end

  test "a job clarification reply stays in household planning in a savings cohort" do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_savings_runtime do
        savings_enroll
        session = @household.chat_sessions.create!(user: @user, cohort: @savings_cohort,
          active_topic: { schema_version: 2, type: "income_schedule", title: "New income", status: "needs_clarification", record_scope: "household_plan",
            action: { type: "create_income_source", income_source_name: "Real salary QA", amount: "3200", cadence: "monthly", effective_on: "2026-10-01" } })
        assert Api::V1::MiaMessagesController.new.send(:household_plan_continuation?, session, "A job income source: Real salary QA, $3200 monthly, starting October 2026.")
        assert Api::V1::MiaMessagesController.new.send(:household_plan_continuation?, session, "job")
        assert Api::V1::MiaMessagesController.new.send(:household_plan_continuation?, session, "$3200")
        assert_not Api::V1::MiaMessagesController.new.send(:household_plan_continuation?, session, "I saved $20 today")
        context = HouseholdFinance::ConversationContextBuilder.new(session, household: @household).call
        assert_equal "3200", context.dig(:active_topic, :action, :amount)
        assert_equal "monthly", context.dig(:active_topic, :action, :cadence)
      end
    end
  end

  test "participant and coach owners cannot use reset capabilities or mutate an earlier admin review" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
    id = flow.preview[:review][:id]
    %w[participant coach].each do |role|
      @user.update!(role: role)
      get "/api/v1/financial_restart/status", headers: auth
      assert_response :success
      assert_equal false, response.parsed_body.dig("financial_restart", "available")
      assert_equal true, response.parsed_body.dig("financial_restart", "admin_required")
      assert_nil response.parsed_body.dig("financial_restart", "latest_review")
      get "/api/v1/financial_restart/status", params: { review_id: id }, headers: auth
      assert_response :forbidden
      %w[preview apply cancel].each do |action|
        post "/api/v1/financial_restart/#{action}", params: { review_id: id, confirmation: "START OVER" }, headers: auth, as: :json
        assert_response :forbidden
        assert_equal "financial_restart_admin_required", response.parsed_body["code"]
      end
      post "/api/v1/mia/messages", params: { message: "Reset everything and start over", request_id: "denied-reset-#{role}" }, headers: auth, as: :json
      assert_response :created
      assert_equal false, response.parsed_body.dig("financial_restart", "available")
      assert_includes response.parsed_body.dig("assistant_message", "content"), "correct your income"
      post "/api/v1/income_sources", params: { income_source: { label: "Allowed #{role}", amount: 200, source_type: "job", cadence: "monthly" } }, headers: auth, as: :json
      assert_response :created
    end
    assert_equal 0, @household.reload.financial_generation
    assert_equal "pending", FinancialRestartReview.find(id).status
  end

  test "platform admin still requires household ownership to restart" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    @household.household_memberships.find_by!(user: @user).update!(role: "partner")
    get "/api/v1/financial_restart/status", headers: auth
    assert_response :success
    assert_equal false, response.parsed_body.dig("financial_restart", "available")
    assert_equal true, response.parsed_body.dig("financial_restart", "owner_required")
    post "/api/v1/financial_restart/preview", headers: auth, as: :json
    assert_response :forbidden
    assert_equal "financial_restart_owner_required", response.parsed_body["code"]
  end

  test "admin role does not bypass private BOG household access" do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 15, 12) do
      with_savings_runtime { savings_enroll }
      @user.update!(role: "admin")
      [ "status", "preview" ].each do |action|
        if action == "status"
          get "/api/v1/financial_restart/status", headers: auth
        else
          post "/api/v1/financial_restart/preview", headers: auth, as: :json
        end
        assert_response :forbidden
        assert_includes response.body, "Participant finances are private"
      end
      assert_equal 0, @household.reload.financial_generation
    end
  end

  test "reset starts empty active chat and separately pages private read-only earlier conversations" do
    @savings_membership.destroy!
    @user.update!(role: "admin")
    session = @household.chat_sessions.create!(user: @user)
    old_messages = 5.times.map do |index|
      session.chat_messages.create!(role: "assistant", content: "Old private message #{index}", financial_restart: { available: true, state: "review_available" })
    end
    other_user = User.create!(clerk_id: "history-other-#{SecureRandom.hex(6)}", email: "history-other-#{SecureRandom.hex(6)}@example.com", role: "participant")
    @household.household_memberships.create!(user: other_user, role: "partner")
    other_session = @household.chat_sessions.create!(user: other_user)
    other_message = other_session.chat_messages.create!(role: "user", content: "Another person's private message")
    flow = HouseholdFinance::FinancialRestart::Flow.new(@household, user: @user)
    preview = flow.preview
    assert_equal true, preview[:review][:clears_chat]
    flow.apply(review_id: preview[:review][:id], confirmation: "START OVER", shared_household_acknowledged: true)
    get "/api/v1/mia/messages", headers: auth
    assert_response :success
    assert_empty response.parsed_body["messages"]
    assert_equal 5, response.parsed_body["historical_message_count"]
    assert_equal false, response.parsed_body["has_older_messages"]
    get "/api/v1/workspace", headers: auth
    assert_response :success
    assert_empty response.parsed_body.dig("mia", "messages")
    fresh = session.chat_messages.create!(role: "user", content: "New real numbers")
    get "/api/v1/mia/messages", params: { before_id: fresh.id }, headers: auth
    assert_response :success
    assert_empty response.parsed_body["messages"]
    assert_equal 0, response.parsed_body["older_message_count"]
    get "/api/v1/mia/messages", params: { picture: "history", limit: 2 }, headers: auth
    assert_response :success
    history = response.parsed_body
    assert_equal true, history["read_only"]
    assert_equal "history", history["picture"]
    assert_empty history["quick_prompts"]
    assert_nil history["disclaimer"]
    assert_equal old_messages.last(2).map(&:id), history["messages"].map { |message| message["id"] }
    assert history["messages"].all? { |message| message["read_only"] && message["financial_restart"].nil? && message["presentation"] == {} }
    assert_equal 3, history["older_message_count"]
    get "/api/v1/mia/messages", params: { picture: "history", limit: 10, before_id: history["oldest_message_id"] }, headers: auth
    assert_response :success
    assert_equal old_messages.first(3).map(&:id), response.parsed_body["messages"].map { |message| message["id"] }
    assert_equal 0, response.parsed_body["older_message_count"]
    assert_equal 7, ChatMessage.where(chat_session: [ session, other_session ]).count
    get "/api/v1/mia/messages", params: { picture: "history" }, headers: { "Authorization" => "Bearer test_token_#{other_user.id}" }
    assert_response :success
    assert_equal [ other_message.id ], response.parsed_body["messages"].map { |message| message["id"] }
    assert_equal 1, response.parsed_body["historical_message_count"]
  end

  private
  def auth
    { "Authorization" => "Bearer test_token_#{@user.id}", "Idempotency-Key" => SecureRandom.uuid }.tap { |headers| headers["X-Cohort-Id"] = @savings_cohort.id.to_s unless @savings_membership.destroyed? }
  end
end
