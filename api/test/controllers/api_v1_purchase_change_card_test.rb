require "test_helper"

# A purchase she already confirmed can be changed, recategorized or taken out
# of spending from the chat. Mia finds it and shows a card; nothing moves
# until she approves, and the old entry stays in her history.
class ApiV1PurchaseChangeCardTest < ActionDispatch::IntegrationTest
  include ActiveSupport::Testing::TimeHelpers

  setup do
    @user = User.create!(clerk_id: "pc_#{SecureRandom.hex(8)}", email: "pc-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
    travel_to Time.zone.local(2026, 11, 11, 12)
    manager = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026)
    @groceries = manager.create_category!(name: "Groceries", stack_key: "discretionary", monthly_amount: 300)
    @shopping = manager.create_category!(name: "Shopping", stack_key: "discretionary", monthly_amount: 200)
    @dining = manager.create_category!(name: "Dining out", stack_key: "discretionary", monthly_amount: 150)
    @runner = HouseholdFinance::Operations::Runner.new(@household, user: @user)
  end

  teardown do
    travel_back
    ENV["OPENROUTER_API_KEY"] = @old_key
  end

  def auth = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def confirmed(merchant, amount, on, category)
    draft = @runner.run(operation_key: "transaction.draft.create", idempotency_key: SecureRandom.uuid,
      input: { occurred_on: on.iso8601, merchant: merchant, amount: amount, budget_category_id: category.id, source_type: "manual_ui" }).subject
    @runner.run(operation_key: "transaction.draft.confirm", input: { draft_id: draft.id, source_type: "manual_ui" }, idempotency_key: SecureRandom.uuid)
    draft.reload
  end

  def say(message)
    post "/api/v1/mia/messages", params: { message: message }, headers: auth, as: :json
    assert_response :created
    response.parsed_body
  end

  def apply(draft)
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply", params: {}, headers: auth.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
  end

  def spent(category, month: 11)
    HouseholdTransaction.joins(:transaction_splits, :budget_period).where(household: @household, status: "confirmed", transaction_splits: { budget_category_id: category.id })
      .where("EXTRACT(MONTH FROM household_transactions.occurred_on) = ?", month).sum("transaction_splits.amount_cents")
  end

  test "an amount correction shows a card, changes nothing until approved, and keeps the old entry in history" do
    purchase = confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    confirmed("Safeway", "80", Date.new(2026, 11, 9), @groceries)

    body = say("the target one yesterday was actually 64 not 46")
    card = body.fetch("mia_action_draft")
    assert_equal "purchase_change", card["draft_type"]
    assert_equal "confirm", card.dig("purchase_change", "mode")
    assert_includes body.dig("budget", "annual_plan", "pending_mia_action_drafts").pluck("id"), card["id"], "the budget carries the card so it shows without a refresh"
    assert_equal [ { "label" => "Amount", "before" => "$46", "after" => "$64" } ], card.dig("purchase_change", "rows")
    assert_includes card.dig("purchase_change", "effects").first, "Shopping, November: $64 spent of your $200 plan, $136 left (was $46 spent)."
    assert_includes body.dig("assistant_message", "content"), "Nothing changes until you do"
    assert_equal 4_600, spent(@shopping), "nothing moved before she approved"
    assert_equal "confirmed", purchase.reload.status

    apply(card)
    assert_response :success
    assert_equal 6_400, spent(@shopping)
    purchase.reload
    assert_equal "corrected", purchase.status
    assert_equal 6_400, purchase.confirmed_transaction.total_amount_cents
    old = @household.household_transactions.where(merchant: "Target", status: "ignored").sole
    assert_equal 4_600, old.total_amount_cents, "the first entry stays in her history"
    assert_equal "draft_reopened", old.metadata["void_reason"]
    assert_match(/Done\. Target now has amount \$64\./, ChatMessage.where(role: "assistant").order(:id).last.content)
  end

  test "a category change moves the purchase and says how Budget moves" do
    confirmed("Costco", "112.40", Date.new(2026, 11, 8), @shopping)

    card = say("that costco one should be groceries").fetch("mia_action_draft")
    assert_equal [ { "label" => "Category", "before" => "Shopping", "after" => "Groceries" } ], card.dig("purchase_change", "rows")
    assert_equal 2, card.dig("purchase_change", "effects").length
    apply(card)
    assert_response :success
    assert_equal 11_240, spent(@groceries)
    assert_equal 0, spent(@shopping)
  end

  test "taking out a purchase says it leaves spending and keeps it as removed" do
    purchase = confirmed("Starbucks", "12", Date.new(2026, 11, 10), @dining)

    body = say("delete the 12 dollar starbucks, it was a refund")
    card = body.fetch("mia_action_draft")
    assert card.dig("purchase_change", "void")
    assert_includes body.dig("assistant_message", "content"), "take it out of your spending"
    assert_equal 1_200, spent(@dining)
    apply(card)
    assert_response :success
    assert_equal 0, spent(@dining)
    assert_equal "ignored", purchase.reload.status
    assert_equal "ignored", purchase.confirmed_transaction&.status || "ignored"
    assert_includes ChatMessage.where(role: "assistant").order(:id).last.content, "out of your spending"
  end

  test "two purchases that fit become choices, and picking one turns the card into the change" do
    confirmed("Target", "46", Date.new(2026, 11, 9), @shopping)
    confirmed("Target", "52", Date.new(2026, 11, 6), @shopping)

    body = say("the target one was actually 64 not 46")
    # The amount narrows it to one, so no choice is needed.
    assert_equal "confirm", body.dig("mia_action_draft", "purchase_change", "mode")

    body = say("change the target purchase to 70")
    card = body.fetch("mia_action_draft")
    assert_equal "choose", card.dig("purchase_change", "mode")
    assert_equal 2, card.dig("purchase_change", "options").length
    apply(card)
    assert_response :unprocessable_entity, "choose a purchase first"

    post "/api/v1/mia_action_drafts/#{card['id']}/purchase_choice", params: { option: 1 }, headers: auth, as: :json
    assert_response :success
    chosen = response.parsed_body.fetch("mia_action_draft")
    assert_equal "confirm", chosen.dig("purchase_change", "mode")
    assert_equal [ "$52", "$70" ], chosen.dig("purchase_change", "rows", 0).values_at("before", "after")
    apply(chosen)
    assert_response :success
    assert_equal [ 4_600, 7_000 ], @household.household_transactions.where(merchant: "Target", status: "confirmed").order(:occurred_on).reverse.pluck(:total_amount_cents).sort
  end

  test "a card that went out of date refuses to apply and changes nothing" do
    purchase = confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    card = say("the target one yesterday was actually 64 not 46").fetch("mia_action_draft")

    @runner.run(operation_key: "transaction.draft.reopen", input: { draft_id: purchase.id, source_type: "manual_ui" }, idempotency_key: SecureRandom.uuid)
    @runner.run(operation_key: "transaction.draft.confirm", input: { draft_id: purchase.id, source_type: "manual_ui", amount: "50", splits: [ { id: purchase.transaction_draft_splits.first.id, budget_category_id: @shopping.id, amount: "50" } ] }, idempotency_key: SecureRandom.uuid)

    apply(card)
    assert_response :unprocessable_entity
    assert_equal "stale_review", response.parsed_body["code"]
    assert_equal 5_000, spent(@shopping)
  end

  test "a purchase from a statement line is not changed from chat" do
    confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    original = TransactionDraft.instance_method(:financial_source_event_id)
    TransactionDraft.define_method(:financial_source_event_id) { 1 }
    begin
      body = say("the target one yesterday was actually 64 not 46")
      assert_nil body["mia_action_draft"]
      assert_includes body.dig("assistant_message", "content"), "came from a statement line"
    ensure
      TransactionDraft.define_method(:financial_source_event_id, original)
    end
    assert_equal 4_600, spent(@shopping)
  end

  test "words that do not point at a confirmed purchase are left to the usual routes" do
    confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    [ "delete the 12 dollar costco, it was a refund", "I spent 64 at Target yesterday", "how much did I spend at Target" ].each do |message|
      body = say(message)
      assert_nil body.dig("mia_action_draft", "purchase_change"), message
    end
    assert_equal 4_600, spent(@shopping)
  end
end
