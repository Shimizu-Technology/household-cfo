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

  test "a purchase still waiting for review keeps its own card unless the old figure names a confirmed one" do
    confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    @runner.run(operation_key: "transaction.draft.create", idempotency_key: SecureRandom.uuid,
      input: { occurred_on: "2026-11-11", merchant: "Target", amount: "30", budget_category_id: @shopping.id, source_type: "manual_ui" })

    assert_nil say("change the target purchase to 70").dig("mia_action_draft", "purchase_change")
    body = say("the target one was actually 64 not 46")
    assert_equal "confirm", body.dig("mia_action_draft", "purchase_change", "mode")
  end

  test "words that do not point at a confirmed purchase are left to the usual routes" do
    confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    [ "delete the 12 dollar costco, it was a refund", "I spent 64 at Target yesterday", "how much did I spend at Target" ].each do |message|
      body = say(message)
      assert_nil body.dig("mia_action_draft", "purchase_change"), message
    end
    assert_equal 4_600, spent(@shopping)
  end

  def with_named_purchase_cap(limit)
    klass = HouseholdFinance::PurchaseChange
    original = klass::MAX_NAMED_PURCHASES
    klass.send(:remove_const, :MAX_NAMED_PURCHASES)
    klass.const_set(:MAX_NAMED_PURCHASES, limit)
    yield
  ensure
    klass.send(:remove_const, :MAX_NAMED_PURCHASES)
    klass.const_set(:MAX_NAMED_PURCHASES, original)
  end

  def choose_option(card_id, option)
    post "/api/v1/mia_action_drafts/#{card_id}/purchase_choice", params: { option: option }, headers: auth, as: :json
  end

  test "an amount or day she names that nothing matches is never dropped: no card for a different purchase" do
    wrong = confirmed("Starbucks", "25", Date.new(2026, 11, 9), @dining)

    body = say("delete the 12 dollar starbucks yesterday, it was a refund")
    card = body.fetch("mia_action_draft")
    assert_equal "choose", card.dig("purchase_change", "mode"), "no confirm card for the $25 purchase"
    assert_equal [ "Starbucks · $25 · Mon, Nov 9" ], card.dig("purchase_change", "options").pluck("label")
    assert_includes body.dig("assistant_message", "content"), "I don't see a Starbucks purchase of $12 from Tue, Nov 10"
    assert_includes body.dig("assistant_message", "content"), "Nothing has changed"
    apply(card)
    assert_response :unprocessable_entity
    assert_equal "confirmed", wrong.reload.status
    assert_equal 2_500, spent(@dining)
  end

  test "the day she names must match too, and the closest purchases are offered, at most three" do
    wrong = confirmed("Starbucks", "25", Date.new(2026, 11, 9), @dining)

    body = say("delete the 25 dollar starbucks from yesterday")
    assert_equal "choose", body.dig("mia_action_draft", "purchase_change", "mode")
    assert_includes body.dig("assistant_message", "content"), "I don't see a Starbucks purchase from Tue, Nov 10"

    [ [ "5", 10 ], [ "7", 8 ], [ "9", 7 ] ].each { |amount, day| confirmed("Starbucks", amount, Date.new(2026, 11, day), @dining) }
    body = say("remove the 12 dollar starbucks, it was a refund")
    options = body.dig("mia_action_draft", "purchase_change", "options")
    assert_equal 3, options.length
    assert_equal [ "Starbucks · $9 · Sat, Nov 7", "Starbucks · $7 · Sun, Nov 8", "Starbucks · $5 · Tue, Nov 10" ], options.pluck("label"), "closest to $12 first"
    assert_equal "confirmed", wrong.reload.status
  end

  test "a figure that is only a date is not read as an amount" do
    purchase = confirmed("Starbucks", "12", Date.new(2026, 11, 9), @dining)
    confirmed("Starbucks", "5", Date.new(2026, 11, 8), @dining)

    body = say("delete the starbucks from Nov 9, it was a refund")
    card = body.fetch("mia_action_draft")
    assert_equal "confirm", card.dig("purchase_change", "mode")
    assert_includes body.dig("assistant_message", "content"), "$12"
    apply(card)
    assert_response :success
    assert_equal "ignored", purchase.reload.status
  end

  test "a replacement amount is never also the one that picks the purchase" do
    confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    confirmed("Target", "70", Date.new(2026, 11, 9), @shopping)

    body = say("change the target purchase to 70")
    card = body.fetch("mia_action_draft")
    assert_equal "choose", card.dig("purchase_change", "mode"), "asks which Target purchase instead of saying nothing needs changing"
    assert_equal [ "Target · $46 · Tue, Nov 10", "Target · $70 · Mon, Nov 9" ], card.dig("purchase_change", "options").pluck("label")
    choose_option(card["id"], 0)
    assert_response :success
    assert_equal [ "$46", "$70" ], response.parsed_body.dig("mia_action_draft", "purchase_change", "rows", 0).values_at("before", "after")
  end

  test "a malformed choice never quietly picks the first purchase" do
    first = confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    confirmed("Target", "52", Date.new(2026, 11, 9), @shopping)
    card = say("change the target purchase to 70").fetch("mia_action_draft")
    assert_equal "choose", card.dig("purchase_change", "mode")

    [ "abc", "-1", "", "1.5", "2", "99", "100", "007x", " " ].each do |bad|
      choose_option(card["id"], bad)
      assert_response :unprocessable_entity, "option #{bad.inspect}"
    end
    post "/api/v1/mia_action_drafts/#{card['id']}/purchase_choice", params: {}, headers: auth, as: :json
    assert_response :unprocessable_entity
    assert_equal "choose", MiaActionDraft.find(card["id"]).metadata.dig("purchase_change", "mode"), "the card is still waiting for a real choice"
    assert_equal 4_600, spent(@shopping) - 5_200
    assert_equal "confirmed", first.reload.status

    choose_option(card["id"], "1")
    assert_response :success
    assert_equal [ "$52", "$70" ], response.parsed_body.dig("mia_action_draft", "purchase_change", "rows", 0).values_at("before", "after")
  end

  test "an explicit future day is never dropped: a same-amount purchase from another day gets no card" do
    purchase = confirmed("Starbucks", "12", Date.new(2026, 11, 9), @dining)

    body = say("delete the $12 starbucks tomorrow, it was a refund")
    assert_nil body["mia_action_draft"], "no card for a purchase from a different day"
    assert_includes body.dig("assistant_message", "content"), "hasn't happened yet"
    assert_includes body.dig("assistant_message", "content"), "Nothing changed"
    assert_equal "confirmed", purchase.reload.status
    assert_equal 1_200, spent(@dining)
    assert_equal 0, MiaActionDraft.where(draft_type: "purchase_change").count
  end

  test "a date in an instead-of correction is never read as the new amount" do
    confirmed("Target", "46", Date.new(2026, 11, 9), @shopping)

    [ "the Target on Nov 9 charged 64 instead of 46", "the Target on Nov 9, 2026 charged 64 instead of 46" ].each do |message|
      body = say(message)
      rows = body.dig("mia_action_draft", "purchase_change", "rows")
      assert rows, "a card for: #{message}"
      assert_equal [ "$46", "$64" ], rows.first.values_at("before", "after"), message
      MiaActionDraft.where(draft_type: "purchase_change").destroy_all
    end
  end

  test "a $0 or too-large amount gets no card the save would refuse" do
    purchase = confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)

    zero = say("change the target purchase to $0")
    assert_nil zero["mia_action_draft"], "no card for $0"
    assert_includes zero.dig("assistant_message", "content"), "can't be $0"

    huge = say("change the target purchase to $50,000,000")
    assert_nil huge["mia_action_draft"], "no card past the money limit"
    assert_equal "confirmed", purchase.reload.status
    assert_equal 0, MiaActionDraft.where(draft_type: "purchase_change").count
  end

  test "conflicting days stay a constraint: a same-amount purchase from another day gets no card" do
    purchase = confirmed("Starbucks", "12", Date.new(2026, 11, 9), @dining)

    body = say("delete the $12 starbucks tomorrow or 2 days ago, it was a refund")
    assert_nil body["mia_action_draft"], "no card when the day she named can't be pinned down"
    assert_includes body.dig("assistant_message", "content"), "couldn't tell which day"
    assert_includes body.dig("assistant_message", "content"), "Nothing changed"
    assert_equal "confirmed", purchase.reload.status
    assert_equal 0, MiaActionDraft.where(draft_type: "purchase_change").count
  end

  test "asking about a different purchase leaves the first card open, and asking again about the same one replaces it" do
    confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    confirmed("Starbucks", "12", Date.new(2026, 11, 10), @dining)

    target = say("the target one was actually 64 not 46").fetch("mia_action_draft")
    starbucks = say("delete the 12 dollar starbucks, it was a refund").fetch("mia_action_draft")
    assert_equal "pending", MiaActionDraft.find(target["id"]).status, "the Target card is about another purchase"
    assert_equal "pending", MiaActionDraft.find(starbucks["id"]).status

    again = say("actually the target one should be 70 not 46").fetch("mia_action_draft")
    assert_equal "canceled", MiaActionDraft.find(target["id"]).status, "same purchase: the older card is replaced"
    assert_equal "pending", MiaActionDraft.find(starbucks["id"]).status
    assert_equal "pending", MiaActionDraft.find(again["id"]).status
  end

  test "a choice whose category has since been archived is refused, never turned into an amount-only change" do
    confirmed("Target", "46", Date.new(2026, 11, 10), @shopping)
    confirmed("Target", "52", Date.new(2026, 11, 9), @shopping)
    card = say("change the target purchase to 70 and put it in groceries").fetch("mia_action_draft")
    assert_equal "choose", card.dig("purchase_change", "mode")
    assert_equal @groceries.id, card.dig("purchase_change", "change", "category_id") if card.dig("purchase_change", "change")

    @groceries.update!(active: false)
    choose_option(card["id"], 0)
    assert_response :unprocessable_entity
    assert_includes response.parsed_body["errors"].join, "category isn't available"
    assert_equal "choose", MiaActionDraft.find(card["id"]).metadata.dig("purchase_change", "mode"), "still waiting; nothing was prepared"
    assert_equal 0, MiaActionDraft.find(card["id"]).mia_action_items.count
  end

  test "choosing a purchase from another year moves the card to that year" do
    confirmed("Starbucks", "12", Date.new(2026, 11, 9), @dining)
    older = confirmed("Starbucks", "9", Date.new(2025, 12, 20), @dining)
    card = say("change the starbucks purchase to 5").fetch("mia_action_draft")
    assert_equal "choose", card.dig("purchase_change", "mode")
    assert_equal 2026, card["year"]

    index = card.dig("purchase_change", "options").index { |option| option["label"].include?("Dec 20, 2025") }
    choose_option(card["id"], index)
    assert_response :success
    chosen = response.parsed_body.fetch("mia_action_draft")
    assert_equal 2025, chosen["year"], "the card follows the purchase she picked"
    assert_equal 2025, MiaActionDraft.find(card["id"]).year
    assert_equal older.id, MiaActionDraft.find(card["id"]).mia_action_items.first.target_record_id
  end

  test "the merchant she names is matched before the cap, so an older purchase is still found" do
    old = confirmed("Starbucks", "12", Date.new(2026, 10, 1), @dining)
    2.times { |index| confirmed("Safeway", (20 + index).to_s, Date.new(2026, 11, 8 + index), @groceries) }

    with_named_purchase_cap(2) do
      card = say("delete the 12 dollar starbucks, it was a refund").fetch("mia_action_draft")
      assert_equal "confirm", card.dig("purchase_change", "mode")
      assert_equal old.id, MiaActionDraft.find(card["id"]).mia_action_items.first.target_record_id
    end
  end

  test "a failed re-confirm rolls the reopen back so the purchase is exactly as it was" do
    purchase = confirmed("Costco", "112.40", Date.new(2026, 11, 8), @shopping)
    card = say("that costco one should be groceries").fetch("mia_action_draft")
    @household.budget_categories.find(@groceries.id).update_columns(active: false)

    assert_no_difference -> { @household.household_transactions.count } do
      apply(card)
    end
    assert_response :unprocessable_entity
    purchase.reload
    assert_equal "confirmed", purchase.status
    assert_equal "confirmed", purchase.confirmed_transaction.status
    assert_equal @shopping.id, purchase.confirmed_transaction.transaction_splits.sole.budget_category_id
    assert_equal 11_240, spent(@shopping)
    assert_equal 0, spent(@groceries)
    assert_equal "pending", MiaActionDraft.find(card["id"]).status
  end

  test "a purchase that came from a statement line is sent to Statements, with a real statement fixture" do
    purchase = confirmed("Payless", "30", Date.new(2026, 11, 10), @groceries)
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "s.csv", content_type: "text/csv", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.csv", checksum_sha256: SecureRandom.hex(32))
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "acct", account_basis: "asset", label: "Spreadsheet account" } ],
      events: [ { account_key: "acct", row_kind: "posted", event_type: "purchase", signed_amount_cents: -3_000, posted_on: "2026-11-10", merchant: "Payless", locator: { page: 1, row: 1 } } ],
      reported_row_count: 1 }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    event = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call[:revision].financial_source_events.sole
    purchase.update_columns(financial_source_event_id: event.id)

    [ "the payless one was actually 35 not 30", "that payless one should be shopping", "delete the 30 dollar payless, it was a refund" ].each do |message|
      body = say(message)
      assert_nil body["mia_action_draft"], message
      assert_includes body.dig("assistant_message", "content"), "came from a statement line", message
    end
    assert_equal 3_000, spent(@groceries)
  end

  test "a split purchase is sent to Spending for changes, but can still be taken out whole" do
    purchase = confirmed("Costco", "100", Date.new(2026, 11, 8), @shopping)
    runner = @runner
    runner.run(operation_key: "transaction.draft.reopen", input: { draft_id: purchase.id, source_type: "manual_ui" }, idempotency_key: SecureRandom.uuid)
    runner.run(operation_key: "transaction.draft.confirm", idempotency_key: SecureRandom.uuid,
      input: { draft_id: purchase.id, source_type: "manual_ui", amount: "100", splits: [ { id: purchase.transaction_draft_splits.first.id, budget_category_id: @shopping.id, amount: "60" }, { budget_category_id: @groceries.id, amount: "40" } ] })
    assert_equal 2, purchase.reload.transaction_draft_splits.count

    body = say("the costco one was actually 120 not 100")
    assert_nil body["mia_action_draft"]
    assert_includes body.dig("assistant_message", "content"), "split across categories"
    body = say("that costco one should be groceries")
    assert_nil body["mia_action_draft"]
    assert_includes body.dig("assistant_message", "content"), "split across categories"

    card = say("delete the 100 dollar costco, it was a refund").fetch("mia_action_draft")
    assert card.dig("purchase_change", "void")
    apply(card)
    assert_response :success
    assert_equal 0, spent(@shopping) + spent(@groceries)
  end

  test "a purchase staged from a bank connection can be changed like any other, and the bank's own row stays untouched" do
    item = @household.plaid_items.create!(connected_by_user: @user, plaid_item_id: "item-#{SecureRandom.hex(4)}", access_token: "token", institution_name: "Test Bank",
      environment: "sandbox", consented_at: Time.current, consent_policy_version: "test", last_synced_at: Time.current)
    account = item.plaid_accounts.create!(plaid_account_id: "acct-#{SecureRandom.hex(4)}", name: "Checking", account_type: "depository", account_subtype: "checking", current_balance_cents: 100_000, active: true)
    purchase = confirmed("Cost-U-Less", "80", Date.new(2026, 11, 10), @groceries)
    row = item.plaid_transactions.create!(plaid_account: account, plaid_transaction_id: "txn-#{SecureRandom.hex(4)}", name: "COST U LESS", occurred_on: Date.new(2026, 11, 10), amount_cents: 8_000,
      pending: false, source_fingerprint: SecureRandom.hex(32), transaction_draft: purchase)

    card = say("the cost-u-less one yesterday should be shopping").fetch("mia_action_draft")
    assert_equal "confirm", card.dig("purchase_change", "mode")
    apply(card)
    assert_response :success
    assert_equal 8_000, spent(@shopping)
    assert_equal 8_000, row.reload.amount_cents, "the bank's own record is never edited"
  end
end
