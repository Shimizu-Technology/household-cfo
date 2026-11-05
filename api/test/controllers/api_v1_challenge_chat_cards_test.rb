require "test_helper"
require_relative "../support/savings_daily_test_support"

class ApiV1ChallengeChatCardsTest < ActionDispatch::IntegrationTest
  include SavingsDailyTestSupport
  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 30, 12)
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end
  teardown do
    ENV["OPENROUTER_API_KEY"] = @old_key
    travel_back
  end

  test "everyday goal words and weekly pace remain proposals until the card is accepted" do
    ask "My goal is three hundred dollars", "words-goal"
    assert_equal 30_000, response.parsed_body.dig("challenge_chat_card", "input", "target_cents")
    ask "I can only do $20 a week", "weekly-goal"
    card = response.parsed_body["challenge_chat_card"]
    assert_equal 25_714, card&.dig("input", "target_cents")
    assert_equal 2_000, card.dig("input", "weekly_cents")
    assert_includes response.parsed_body.dig("assistant_message", "content"), "$257.14"
    assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
    confirm(card)
    assert_equal 25_714, @savings_enrollment.reload.current_accepted_plan_version.target_cents
    ask "Actually lets just do a thousand", "words-replacement"
    assert_equal 100_000, response.parsed_body.dig("challenge_chat_card", "input", "target_cents")
    ask "I can set aside twenty dollars per week", "weekly-set-aside-goal"
    assert_equal 25_714, response.parsed_body.dig("challenge_chat_card", "input", "target_cents")
    assert_equal 0, SavingsEntryVersion.count
  end

  test "yes keeps savings review durable without adding money" do
    ask "I set aside $25 today", "reserve"
    card = response.parsed_body["challenge_chat_card"]
    assert_equal "savings", card&.fetch("kind")
    [ "Yes", "Yes, save it" ].each_with_index do |message, index|
      assert_no_difference [ "SavingsEntryDraft.count", "SavingsEntryVersion.count" ] do
        ask message, "reserve-yes-#{index}"
      end
      assert_equal card["id"], response.parsed_body.dig("challenge_chat_card", "id")
      assert_match(/nothing.*saved/i, response.parsed_body.dig("assistant_message", "content"))
      get "/api/v1/savings_challenge/chat_cards", headers: auth
      assert_equal card["id"], response.parsed_body.fetch("records").sole["id"]
    end
  end

  { "I withdrew $5 from savings today" => "savings", "I spent $12 at Payless today" => "daily_report", "Set my goal to $300" => "goal" }.each_with_index do |(message, kind), index|
    test "yes points back to the existing #{kind} review #{index} without approving it" do
      ask message, "review-kind-#{index}"
      card = response.parsed_body.fetch("challenge_chat_card")
      assert_equal kind, card["kind"]
      assert_no_difference [ "SavingsEntryVersion.count", "SavingsPlanVersion.count", "SavingsDailyPurchaseVersion.count" ] do
        ask "Yes, save it", "review-kind-yes-#{index}"
      end
      assert_equal card["id"], response.parsed_body.dig("challenge_chat_card", "id")
      assert_match(/nothing has been saved/i, response.parsed_body.dig("assistant_message", "content"))
      assert_equal "pending", SavingsChatCard.find(card["id"]).status
    end
  end

  test "a savings correction names the current entry and a total question is brief" do
    with_savings_runtime { savings_approve(savings_draft(2_000)) }
    ask "Actually the $20 I set aside was really $15", "correct-savings"
    card = response.parsed_body["challenge_chat_card"]
    assert_equal "savings", card&.fetch("kind")
    assert_equal 1_500, card.dig("input", "amount_cents")
    assert_equal 2_000, card.dig("input", "correction", "current_approved_version", "signed_cents")
    assert_match(/replace.*\$20.*\$15/i, response.parsed_body.dig("assistant_message", "content"))
    assert_equal 2_000, savings_projection[:reported_cents]
    ask "How much have I saved so far?", "savings-total"
    answer = response.parsed_body.dig("assistant_message", "content")
    assert_match(/\A.*\$20/, answer)
    assert_operator answer.length, :<, 180
  end

  test "entry history labels a replaced amount without double counting it" do
    with_savings_runtime do
      version = savings_approve(savings_draft(2_500))
      savings_approve(savings_draft(2_000, entry: version.savings_entry))
    end
    get "/api/v1/savings_challenge/entry_drafts", params: { status: "approved" }, headers: auth
    assert_response :success
    rows = response.parsed_body.fetch("records").index_by { |row| row["signed_cents"] }
    assert_equal true, rows.fetch(2_500).fetch("replaced")
    assert_equal false, rows.fetch(2_000).fetch("replaced")
    assert_equal 2_000, savings_projection[:reported_cents]
  end

  test "a dismissed savings card cannot stage a new draft" do
    ask "I set aside $25 today", "dismiss-reserve"
    card = response.parsed_body.fetch("challenge_chat_card")
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { action: "dismiss", expected_lock_version: card["lock_version"] }, headers: auth, as: :json
    assert_response :success
    assert_no_difference [ "SavingsEntryDraft.count", "SavingsEntryVersion.count" ] do
      post "/api/v1/savings_challenge/entry_drafts", params: { signed_cents: 2_500, effective_on: @savings_enrollment.local_today.iso8601, funding_source: "new_money_reserved", expected_version_id: nil, chat_card_id: card["id"] }, headers: auth.merge("Idempotency-Key" => "after-dismiss"), as: :json
    end
    assert_response :conflict
    assert_includes response.parsed_body.fetch("errors").join, "already reviewed"
    assert_equal({}, SavingsChatCard.find(card["id"]).state)
  end

  test "reviewing a savings card hands off once to a retained savings draft" do
    ask "I set aside $25 today", "reserve-for-form"
    card = response.parsed_body.fetch("challenge_chat_card")
    input = { signed_cents: 2_500, effective_on: @savings_enrollment.local_today.iso8601, funding_source: "new_money_reserved", expected_version_id: nil, chat_card_id: card["id"] }
    post "/api/v1/savings_challenge/entry_drafts", params: input, headers: auth.merge("Idempotency-Key" => "savings-form"), as: :json
    assert_response :success
    assert_equal "closed", SavingsChatCard.find(card["id"]).status
    assert_equal 1, SavingsEntryDraft.count
    assert_equal 0, SavingsEntryVersion.count
    post "/api/v1/savings_challenge/entry_drafts", params: input, headers: auth.merge("Idempotency-Key" => "savings-form"), as: :json
    assert_response :success
    post "/api/v1/savings_challenge/entry_drafts", params: input, headers: auth.merge("Idempotency-Key" => "savings-form-second"), as: :json
    assert_response :conflict
    assert_equal 1, SavingsEntryDraft.count
  end

  [ "I'd like my goal to be $500 by the end of the 90 days.", "Set my challenge target to $500.",
    "Set my goal to $500.", "I want to save $500" ].each_with_index do |message, index|
    test "explicit target phrasing #{index} returns an honest pending chat card" do
      assert_no_difference [ "SavingsPlanDraft.count", "SavingsPlanVersion.count", "SavingsEntryVersion.count" ] do
        ask message, "explicit-target-#{index}"
      end
      card = response.parsed_body.fetch("challenge_chat_card")
      assert card, response.parsed_body.inspect
      assert_equal "goal", card["kind"]
      assert_equal "pending", card["status"]
      assert_equal 50_000, card.dig("input", "target_cents")
      assert_includes response.parsed_body.dig("assistant_message", "content"), "I've set up a $500 target for you to confirm below"
      refute_match(/nothing (?:has )?changed/i, response.parsed_body.dig("assistant_message", "content"))
      assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
      get "/api/v1/savings_challenge/chat_cards", headers: auth
      assert_equal card, response.parsed_body.fetch("records").sole
      confirm(card)
      assert_equal 50_000, @savings_enrollment.reload.current_accepted_plan_version.target_cents
    end
  end

  test "a bare amount answers the target question without patterns or a previous card" do
    ask "Set my challenge target", "ask-target"
    assert_includes response.parsed_body.dig("assistant_message", "content"), "What comfortable amount"
    assert_nil response.parsed_body["challenge_chat_card"]
    ask "$500", "answer-target"
    assert_equal 50_000, response.parsed_body.dig("challenge_chat_card", "input", "target_cents")
    assert_includes response.parsed_body.dig("assistant_message", "content"), "I've set up a $500 target for you to confirm below"
    assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
  end

  test "bare amount after patterns is not a goal but a pending goal supplies context" do
    ask "What patterns do you see?", "patterns-context"
    refute SavingsChallenge::ChatTurn.special?("500", session: ChatSession.order(:id).last)
    ask "500", "merchant-answer"
    assert_nil response.parsed_body["challenge_chat_card"]
    ask "Set my goal to $300", "pending-context"
    ChatSession.order(:id).last.update!(active_topic: { type: "challenge_patterns" })
    ask "500", "pending-answer"
    assert_equal 50_000, response.parsed_body.dig("challenge_chat_card", "input", "target_cents")
  end

  { "Change my goal from $500 to 300" => 30_000,
    "I want my goal to be $500 instead of $400" => 50_000,
    "I want to save $500 instead of $400" => 50_000,
    "I want to save $100 a month, so change my goal to $500" => 50_000 }.each_with_index do |(message, cents), index|
    test "replacement phrasing #{index} chooses the requested amount before confirmation" do
      ask message, "replacement-#{index}"
      card = response.parsed_body.fetch("challenge_chat_card")
      assert_equal cents, card&.dig("input", "target_cents")
      assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
      confirm(card)
      assert_equal cents, @savings_enrollment.reload.current_accepted_plan_version.target_cents
    end
  end

  test "malformed replacement cannot select the old amount" do
    ask "Set my goal to $500.259 instead of $400", "malformed-replacement"
    assert_nil response.parsed_body["challenge_chat_card"]
    assert_includes response.parsed_body.dig("assistant_message", "content"), "What comfortable amount"
  end

  test "target amounts retain cents and reject malformed decimals rather than truncating" do
    ask "Set my target to $500.25.", "cents-target"
    assert_equal 50_025, response.parsed_body.dig("challenge_chat_card", "input", "target_cents")
    ask "Set my target to $500.259", "invalid-target"
    assert_nil response.parsed_body["challenge_chat_card"]
    assert_includes response.parsed_body.dig("assistant_message", "content"), "What comfortable amount"
  end

  test "a fresh read restores check-in inputs, feelings and interrupted keys; dismiss and replay cannot resurrect it" do
    ask "Today I spent $14.75 at Kmart on snacks for the kids. I felt rushed when I bought it and now I feel guilty.", "daily"
    card = response.parsed_body.fetch("challenge_chat_card")
    assert_equal "daily_report", card["kind"]
    answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes answer, "Being rushed"
    assert_includes answer, "doesn't mean you failed"
    refute_includes answer, "How did you feel"
    assert_equal 0, SavingsDailyPurchaseVersion.count
    get "/api/v1/savings_challenge/chat_cards", headers: auth
    assert_response :success
    assert_equal card, response.parsed_body.fetch("records").sole
    state = { rows: [ { id: 0, status: "unknown" } ], unconfirmed: { key: "same-approval", action: "purchase_approve", input: { draft_id: 123 } } }
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { action: "save_state", expected_lock_version: 0, state: state }, headers: auth, as: :json
    assert_response :success
    get "/api/v1/savings_challenge/chat_cards", headers: auth
    restored = response.parsed_body.fetch("records").sole
    assert_equal state.deep_stringify_keys, restored["state"]
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { action: "dismiss", expected_lock_version: restored["lock_version"] }, headers: auth, as: :json
    assert_response :success
    get "/api/v1/savings_challenge/chat_cards", headers: auth
    assert_empty response.parsed_body.fetch("records")
    ask "Today I spent $14.75 at Kmart on snacks for the kids. I felt rushed when I bought it and now I feel guilty.", "daily"
    assert_equal "closed", response.parsed_body.dig("challenge_chat_card", "status")
    assert_nil SavingsChatCard.find(card["id"]).input["feelings"]
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { action: "save_state", expected_lock_version: restored["lock_version"], state: state }, headers: auth, as: :json
    assert_response :conflict
  end

  test "goal confirmation uses reviewed operations once and chat revision replaces the earlier proposal" do
    ask "Help me choose a comfortable savings target", "target"
    card = response.parsed_body.fetch("challenge_chat_card")
    assert_equal 50_000, card.dig("input", "target_cents")
    assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
    assert_equal 0, SavingsPlanDraft.count
    confirm(card)
    assert_equal 50_000, @savings_enrollment.reload.current_accepted_plan_version.target_cents
    assert_equal 1, SavingsPlanVersion.count
    confirm(card) # lost response / repeat tap replays without another version
    assert_equal 1, SavingsPlanVersion.count
    ask "Let's do $400 instead", "target-400"
    revision = response.parsed_body.fetch("challenge_chat_card")
    assert_equal 40_000, revision.dig("input", "target_cents")
    assert_equal 50_000, @savings_enrollment.reload.current_accepted_plan_version.target_cents
    assert_includes response.parsed_body.dig("assistant_message", "content"), "I've set up a $400 target for you to confirm below"
    refute_includes response.parsed_body.dig("assistant_message", "content"), "$400.00"
    confirm(revision)
    assert_equal 40_000, @savings_enrollment.reload.current_accepted_plan_version.target_cents
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { action: "approve_goal", expected_lock_version: card["lock_version"], accepted: true }, headers: auth, as: :json
    assert_response :conflict
    assert_nil SavingsChallenge::Projection.new(@savings_enrollment).call[:reported_cents]
  end

  test "a replaced or dismissed goal cannot report approval success" do
    ask "Set my goal to $500", "first-goal"
    first = response.parsed_body.fetch("challenge_chat_card")
    ask "Set my goal to $400", "replacement-goal"
    replacement = response.parsed_body.fetch("challenge_chat_card")
    post "/api/v1/savings_challenge/chat_cards/#{first['id']}", params: { action: "approve_goal", expected_lock_version: first["lock_version"], accepted: true }, headers: auth, as: :json
    assert_response :conflict
    assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
    post "/api/v1/savings_challenge/chat_cards/#{replacement['id']}", params: { action: "dismiss", expected_lock_version: replacement["lock_version"] }, headers: auth, as: :json
    assert_response :success
    post "/api/v1/savings_challenge/chat_cards/#{replacement['id']}", params: { action: "approve_goal", expected_lock_version: replacement["lock_version"], accepted: true }, headers: auth, as: :json
    assert_response :conflict
    assert_equal 0, SavingsPlanVersion.count
  end

  test "a question containing money does not choose option one, and a merchant-only reply can choose" do
    session = ChatSession.create!(household: @savings_household, user: @savings_user, cohort: @savings_cohort)
    session.update!(active_topic: { type: "challenge_patterns", choices: [
      { merchant: "Ross", label: "Cut back on Ross", description: "Spend half as much at Ross", monthly_impact_cents: 10_000 },
      { merchant: "Kmart", label: "Cut back on Kmart", description: "Spend half as much at Kmart", monthly_impact_cents: 6_000 }
    ] })
    ask "What do I do with my money?", "choice-question"
    assert_nil response.parsed_body["challenge_chat_card"]
    assert_includes response.parsed_body.dig("assistant_message", "content"), "Would you feel more comfortable"
    ask "Ross", "choice-merchant"
    reply = response.parsed_body.dig("assistant_message", "content")
    assert_includes reply, "Spending half as much at Ross could free about $100 a month"
    refute_match(/Trying try|at ross|\$100\.00/, reply)
    assert_equal 50_000, response.parsed_body.dig("challenge_chat_card", "input", "target_cents")
  end

  test "patterns name missing months in one clause and keep merchant display names" do
    category = @savings_household.budget_categories.create!(name: "Optional shopping", stack_key: "discretionary", sort_order: 1)
    year = @savings_household.budget_years.create!(year: 2026)
    [ [ 8, "Ross", 20_000 ], [ 10, "Kmart", 10_000 ] ].each do |month, merchant, cents|
      date = Date.new(2026, month, 5)
      period = year.budget_periods.create!(starts_on: date.beginning_of_month, ends_on: date.end_of_month)
      row = @savings_household.household_transactions.create!(budget_period: period, occurred_on: date, merchant: merchant, total_amount_cents: cents, source_type: "statement", status: "confirmed")
      row.transaction_splits.create!(budget_category: category, amount_cents: cents)
    end
    ask "Can you identify spending patterns?", "partial-patterns"
    reply = response.parsed_body.dig("assistant_message", "content")
    assert_includes reply, "I only see purchases for Aug and Oct:"
    assert_includes reply, "Ross ($200) and Kmart ($100)"
    refute_includes reply, "Only confirmed purchases"
    refute_includes reply, ".00"
    assert_equal 3, reply.split(Mia::ResponseShapePolicy::SENTENCE_BOUNDARY).length
    assert_nil response.parsed_body.dig("spending_patterns", "coverage", "months", 1, "spending_cents")
  end

  test "polite goal changes and old-to-new amounts prepare the requested review only" do
    [ "Can we change my goal to $300?", "Please set my target to $300 instead of $500.", "Change my goal from $500 to $300", "Let's do $300 instead of $500 for my goal", "Make it $300 instead of $500 for my goal" ].each_with_index do |message, index|
      ask message, "polite-target-#{index}"
      assert_equal 30_000, response.parsed_body.dig("challenge_chat_card", "input", "target_cents"), message
      assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
      assert_equal 0, SavingsPlanVersion.count
    end
  end

  test "goal consent, stale versions, cross-participant and historical cards fail closed" do
    ask "Set my goal to $400", "target"
    card = response.parsed_body.fetch("challenge_chat_card")
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { action: "approve_goal", expected_lock_version: 0 }, headers: auth, as: :json
    assert_response :unprocessable_entity
    with_savings_runtime { savings_plan(30_000) }
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { action: "approve_goal", expected_lock_version: 0, accepted: true }, headers: auth, as: :json
    assert_response :conflict
    assert_equal 30_000, @savings_enrollment.reload.current_accepted_plan_version.target_cents
    other = User.create!(clerk_id: "other-#{SecureRandom.hex(6)}", email: "other-#{SecureRandom.hex(6)}@example.invalid", role: "participant", invitation_status: "accepted")
    get "/api/v1/savings_challenge/chat_cards", headers: auth.merge("Authorization" => "Bearer test_token_#{other.id}")
    assert_response :unprocessable_entity
    ChatMessage.where(id: card["message_id"]).update_all(financial_generation: -1)
    get "/api/v1/savings_challenge/chat_cards", headers: auth
    assert_empty response.parsed_body.fetch("records")
  end

  test "purchase and no-spend reports containing checkpoint or subscription words keep their intake" do
    ask "Day 30: Today I spent $15 at Stream subscription.", "day30-purchase"
    assert_equal "daily_report", response.parsed_body.dig("challenge_chat_card", "kind")
    assert_equal 1_500, response.parsed_body.dig("challenge_chat_card", "input", "purchases", 0, "amount_cents")
    assert_nil response.parsed_body["spending_patterns"]
    ask "Day 30: No spending today", "day30-no-spend"
    assert_equal true, response.parsed_body.dig("challenge_chat_card", "input", "no_spend")
    assert_equal 0, SavingsDailyPurchaseVersion.count
  end

  test "checkpoint projection exposes Day 30 due and preserves unknown timeline days" do
    # An enrollment starts on acceptance; advance rather than rewriting its dates.
    travel 29.days
    get "/api/v1/savings_challenge", headers: auth
    assert_response :success
    timeline = response.parsed_body.fetch("timeline")
    assert_equal 90, timeline.fetch("days").length
    assert_equal [ 30 ], timeline.fetch("checkpoints_due")
    assert_equal "unknown", timeline.fetch("days").first["check_in"]
    assert_nil timeline.fetch("days").first["deposit_cents"]
    assert_equal true, timeline.fetch("days")[30]["future"]
    ask "Where am I at day 30?", "day30"
    assert_includes response.parsed_body.dig("assistant_message", "content"), "Day 30 is ready to review"
  end

  test "progress describes an exact-cent net withdrawal without reporting it as money set aside" do
    with_savings_runtime do
      savings_plan(50_000)
      savings_approve(savings_draft(500))
      savings_approve(savings_draft(-1_550, funding: "withdrawal"))
    end
    ask "Where am I at day 30?", "negative-progress"
    answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes answer, "taken out $10.50 more than you've set aside"
    assert_includes answer, "your goal is $500"
    refute_includes answer, "$-11.50"
    assert_equal(-1_050, SavingsChallenge::Projection.new(@savings_enrollment.reload).call[:reported_cents])
  end

  test "a debt participant gets the cushion explanation and an actual destination" do
    ask "I joined to pay down my credit card, how does this help?", "debt"
    answer = response.parsed_body.dig("assistant_message", "content")
    assert_includes answer, "unexpected bill"
    assert_includes answer, "Optional card & debt review in Savings"
    refute_match(/APR|snowball|avalanche|liquidity/, answer)
    assert_nil response.parsed_body["challenge_chat_card"]
  end

  test "essential hardship and crisis interrupt patterns and goal cards without financial proposals" do
    [ "patterns", "goal" ].each do |previous|
      {
        "I can't afford rent this month, what should I do?" => "Protect food, housing, medication",
        "I can't afford food this month, what should I do?" => "Food comes first",
        "I can't afford medicine this month, what should I do?" => "Protect food, housing, medication",
        "I want to kill myself. What should I do about my goal?" => "988"
      }.each_with_index do |(message, expected), index|
        if previous == "patterns"
          ask "Can you identify spending patterns?", "safety-setup-patterns-#{index}"
          ChatSession.find_by!(user: @savings_user, household: @savings_household).update!(active_topic: {
            type: "challenge_patterns", choices: [ { merchant: "Ross", monthly_impact_cents: 10_000 }, { merchant: "Kmart", monthly_impact_cents: 6_000 } ]
          })
        else
          ask "Set my goal to $500", "safety-setup-goal-#{index}"
        end
        ask message, "safety-#{previous}-#{index}"
        answer = response.parsed_body.dig("assistant_message", "content")
        assert_includes answer, expected, message
        refute_includes answer, "Would you feel more comfortable cutting back"
        assert_nil response.parsed_body["challenge_chat_card"]
        refute_equal "challenge_patterns", ChatSession.find_by!(user: @savings_user, household: @savings_household).active_topic["type"]
      end
    end
    assert_equal 0, SavingsPlanVersion.count
  end

  test "ordinal and merchant replies choose the option they name" do
    choices = [ { merchant: "Ross", monthly_impact_cents: 10_000 }, { merchant: "Kmart", monthly_impact_cents: 6_000 } ]
    session = ChatSession.create!(household: @savings_household, user: @savings_user, cohort: @savings_cohort)
    { "the second one" => "Kmart", "the one at Kmart" => "Kmart", "the first one" => "Ross" }.each_with_index do |(message, merchant), index|
      session.reload.update!(active_topic: { type: "challenge_patterns", choices: choices })
      ask message, "ordinal-#{index}"
      assert_includes response.parsed_body.dig("assistant_message", "content"), "Spending half as much at #{merchant}", message
    end
  end

  test "a bare amount outside a goal conversation never becomes a goal card" do
    [ "Make it $30", "Let's do $20 at Kings for lunch" ].each_with_index do |message, index|
      ask message, "bare-amount-#{index}"
      refute_equal "goal", response.parsed_body.dig("challenge_chat_card", "kind"), message
    end
    assert_equal 0, SavingsChatCard.where(kind: "goal").count
    ask "Set my goal to $300", "pending-before-purchase"
    pending = response.parsed_body.fetch("challenge_chat_card")
    ask "Let's do $20 at Kings for lunch", "purchase-with-pending-goal"
    refute_equal "goal", response.parsed_body.dig("challenge_chat_card", "kind")
    assert_equal "pending", SavingsChatCard.find(pending["id"]).status

    # In a household-plan thread, "Make it $30" corrects the plan, not the goal.
    session = ChatSession.find_by!(household: @savings_household, user: @savings_user)
    session.update_columns(active_topic: { "type" => "household_inventory", "record_scope" => "household_plan" })
    ask "Make it $30", "household-plan-correction"
    refute_equal "goal", response.parsed_body.dig("challenge_chat_card", "kind")
    assert_equal "pending", SavingsChatCard.find(pending["id"]).status
    assert_equal 1, SavingsChatCard.where(kind: "goal", status: "pending").count
  end

  test "mentioning an existing goal amount preserves a pending proposal" do
    ask "Set my goal to $300", "pending-goal"
    pending = response.parsed_body.fetch("challenge_chat_card")
    [ "What happens if I miss my goal of $500?", "What should I do about my goal of $500?" ].each_with_index do |message, index|
      ask message, "mention-goal-#{index}"
      assert_nil response.parsed_body["challenge_chat_card"], message
      assert_equal "pending", SavingsChatCard.find(pending["id"]).status
      assert_equal 1, SavingsChatCard.where(kind: "goal", status: "pending").count
    end
    [ "Make it $400", "Let's do $400", "Change my goal to $400" ].each_with_index do |message, index|
      ask message, "explicit-goal-#{index}"
      assert_equal 40_000, response.parsed_body.dig("challenge_chat_card", "input", "target_cents"), message
    end
    assert_nil @savings_enrollment.reload.current_accepted_plan_version_id
  end

  private
  def auth = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }
  def ask(message, request_id)
    post "/api/v1/mia/messages", params: { message: message, request_id: request_id }, headers: auth, as: :json
    assert_response :created
  end
  def confirm(card)
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { action: "approve_goal", expected_lock_version: card["lock_version"], accepted: true }, headers: auth, as: :json
    assert_response :success
  end
end
