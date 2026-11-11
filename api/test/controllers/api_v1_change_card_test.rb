require "test_helper"

# After setup, every household field changes through the same change card:
# one row per change, Apply, then one plain sentence. Bills are their own
# budget rows, so one bill can go or change without touching the rest.
class ApiV1ChangeCardTest < ActionDispatch::IntegrationTest
  EMPTY_MONEY = { none: false, total_amount: "", total_cadence: "", total_count: "", total_source: "", parts: [] }.freeze
  EMPTY_DEBT = { none: false, total_amount: "", total_source: "", parts: [] }.freeze
  EMPTY_BALANCE = { amount: "", source: "" }.freeze

  setup do
    @user = User.create!(clerk_id: "chg_#{SecureRandom.hex(8)}", email: "chg-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end
  teardown { ENV["OPENROUTER_API_KEY"] = @old_key }

  def changes(**over)
    { household_name: "", primary_goal: "", primary_income: EMPTY_MONEY, business_income: EMPTY_MONEY, fixed_expenses: EMPTY_MONEY, flexible_spend: EMPTY_MONEY,
      expected_sinking_fund: EMPTY_MONEY, unexpected_sinking_fund: EMPTY_MONEY, emergency_fund: EMPTY_BALANCE, other_assets: EMPTY_BALANCE, credit_card_debt: EMPTY_BALANCE,
      debt_payment: EMPTY_DEBT, target_runway_months: { months: "", source: "" }, skips: [], help_topic: "", work_out: false, confirm_monthly: false }.merge(over)
  end

  def read(question: false, setup: changes, facts: [], care: "none")
    { care: care, facts: facts, question: question, care_status: "none", spending_preferences: [], setup_changes: setup }
  end

  def money(**values) = EMPTY_MONEY.merge(values)
  def debts(**values) = EMPTY_DEBT.merge(values)
  def part(op, label, amount, source: nil) = { op: op, label: label, amount: amount, cadence: amount.empty? ? "" : "monthly", count: "", source: source || [ label, amount ].join(" ") }
  def debt(op, name, minimum, source: "") = { op: op, name: name, minimum: minimum, balance: "", source: source }

  def say(message, data, intent: nil)
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    captured = nil
    klass.define_singleton_method(:call) do |**options|
      captured = options
      new(**options.merge(transport: ->(_payload) { JSON.generate(data) })).call
    end
    resolver = HouseholdFinance::MiaIntentResolver
    original_resolve = resolver.instance_method(:call)
    asked = false
    resolver.define_method(:call) { asked ? nil : (asked = true; intent) } if intent # only the controller's own read; later parsers see no model
    post "/api/v1/mia/messages", params: { message: message }, headers: auth, as: :json
    assert_response :created
    @last_reader_options = captured
    response.parsed_body
  ensure
    klass.define_singleton_method(:call, original)
    resolver.define_method(:call, original_resolve)
  end

  def auth = { "Authorization" => "Bearer test_token_#{@user.id}" }
  def text(body) = body.dig("assistant_message", "content")
  def card_of(body) = body.dig("budget", "annual_plan", "pending_mia_action_drafts").to_a.find { |draft| draft["setup_card"] }
  def rows(body) = card_of(body).dig("setup_card", "rows")
  def row(body, key) = rows(body).find { |item| item["key"] == key }
  def last_reply = ChatMessage.where(role: "assistant").order(:id).last.content

  def apply(draft)
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply", params: {}, headers: auth.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    response.parsed_body.fetch("workspace")
  end

  def home(workspace) = workspace.fetch("dashboard").fetch("month_answer")
  def values = HouseholdFinance::DataPresenter.new(@household.reload, ensure_plan: false).setup_values
  def stack_names(stack) = @household.budget_categories.active.where(stack_key: stack).order(:id).pluck(:name)

  def finish_setup
    body = say("taitano. get ahead. 5200 income. rent 1650 power 180 insurance 120. everyday 600. visa 75 n truck 310", read(setup: changes(household_name: "taitano", primary_goal: "get ahead",
      primary_income: money(total_amount: "5200", total_cadence: "monthly", total_source: "5200 income"),
      fixed_expenses: money(parts: [ part("add", "rent", "1650"), part("add", "power", "180"), part("add", "insurance", "120") ]),
      flexible_spend: money(total_amount: "600", total_cadence: "monthly", total_source: "everyday 600"),
      debt_payment: debts(parts: [ debt("add", "visa", "75", source: "visa 75"), debt("add", "truck", "310", source: "truck 310") ]))))
    workspace = apply(card_of(body))
    assert_equal [], HouseholdFinance::SetupStatus.new(@household.reload).missing_field_keys
    assert_equal %w[Rent Power Insurance], stack_names("non_discretionary"), "each named bill is its own budget row"
    workspace
  end

  test "taking one bill off is a one-row card, and Home's money out drops by that bill" do
    before = home(finish_setup)
    body = say("we cancelled the insurance so take that off", read(setup: changes(fixed_expenses: money(parts: [ part("remove", "insurance", "", source: "we cancelled the insurance so take that off") ]))))
    assert_equal [ "Insurance $120", "Power $180", "Rent $1,650" ].sort, @last_reader_options[:setup_context][:saved_bills]["fixed_expenses"].sort
    assert card_of(body), text(body)
    assert_equal [ "fixed_expenses" ], rows(body).map { |item| item["key"] }
    fixed = row(body, "fixed_expenses")
    assert_equal 183_000, fixed["total_cents"]
    assert_equal [ [ "Insurance", true ] ], fixed["parts"].map { |item| [ item["label"], item["removed"] ] }
    assert_equal "Rent and Power stay as they are.", fixed["note"]
    assert_equal "Your changes", card_of(body)["title"]
    assert_match(/Took out insurance\. Fixed essentials would be \$1,830 a month\./, text(body))
    assert_equal 195_000, (values[:fixed_expenses].to_f * 100).round, "nothing changes before Apply"

    after = home(apply(card_of(body)))
    assert_equal before.fetch("planned_out_cents") - 12_000, after.fetch("planned_out_cents")
    assert_equal %w[Rent Power], stack_names("non_discretionary")
    assert_equal 1830.0, values[:fixed_expenses].to_f
    assert_equal "Done: insurance is off and fixed essentials are $1,830 a month.", last_reply
  end

  test "a bill that went up changes only that bill" do
    finish_setup
    body = say("the rent went up to 1700", read(setup: changes(fixed_expenses: money(parts: [ part("replace", "rent", "1700", source: "the rent went up to 1700") ]))))
    assert_equal [ [ "Rent", 170_000 ] ], row(body, "fixed_expenses")["parts"].map { |item| [ item["label"], item["cents"] ] }
    apply(card_of(body))
    assert_equal 2000.0, values[:fixed_expenses].to_f
    rent = @household.expense_items.find_by!(label: "Rent", active: true)
    assert_equal 170_000, rent.amount_cents
    assert_equal %w[Rent Power Insurance], stack_names("non_discretionary")
  end

  test "a new bill is added as its own row" do
    finish_setup
    body = say("add phone 60", read(setup: changes(fixed_expenses: money(parts: [ part("add", "phone", "60", source: "add phone 60") ]))))
    assert_equal [ "Phone" ], row(body, "fixed_expenses")["parts"].map { |item| item["label"] }
    apply(card_of(body))
    assert_equal %w[Rent Power Insurance Phone], stack_names("non_discretionary")
    assert_equal 2010.0, values[:fixed_expenses].to_f
  end

  test "emergency fund, runway, debt minimums and a paid-off debt change by chat" do
    finish_setup
    fund = say("my emergency fund is 1200 now", read(setup: changes(emergency_fund: { amount: "1200", source: "my emergency fund is 1200 now" })))
    assert_equal [ "emergency_fund" ], rows(fund).map { |item| item["key"] }
    assert_equal 120_000, row(fund, "emergency_fund")["total_cents"]
    runway = say("make my runway goal 3 months", read(setup: changes(target_runway_months: { months: "3", source: "make my runway goal 3 months" })))
    assert_equal card_of(fund)["id"], card_of(runway)["id"], "one card collects the changes"
    assert_equal "3 months", row(runway, "target_runway_months")["value_text"]
    visa = say("the visa min is 95 now", read(setup: changes(debt_payment: debts(parts: [ debt("replace", "visa", "95", source: "the visa min is 95 now") ]))))
    truck = say("paid off the truck, take it off", read(setup: changes(debt_payment: debts(parts: [ debt("remove", "truck", "") ]))))
    debt_row = row(truck, "debt_payment")
    assert_equal [ [ "Truck", 31_000, true ], [ "Visa", 9_500, nil ] ], debt_row["parts"].map { |item| [ item["label"], item["cents"], item["removed"] ] }.sort_by(&:first)
    assert_equal 9_500, debt_row["total_cents"]
    assert visa
    apply(card_of(truck))
    @household.reload
    assert_equal 1200.0, values[:emergency_fund].to_f
    assert_equal 3.0, values[:target_runway_months].to_f
    assert_equal [ [ "Visa", 9_500 ] ], @household.debts.active.pluck(:label, :minimum_payment_cents)
  end

  test "pay every two weeks after setup is offered as a month, and yes saves it" do
    finish_setup
    body = say("i get paid 1950 every 2 weeks now", read(setup: changes(primary_income: money(total_amount: "1950", total_cadence: "biweekly", total_source: "i get paid 1950 every 2 weeks now"))))
    assert_match(/That's about \$4,225 a month \(1,950 × 26 ÷ 12\)\. Use \$4,225\?\z/, text(body))
    assert_equal false, card_of(body).dig("setup_card", "can_apply")
    yes = say("yes", read)
    assert_equal 422_500, row(yes, "primary_income")["total_cents"]
    apply(card_of(yes))
    assert_equal 4225.0, values[:primary_income].to_f
  end

  test "a total with one part inside it keeps both, never double counted" do
    say("Help me set up my household", read)
    body = say("actually bills bout 2000 total, rent is 1500 of that", read(setup: changes(fixed_expenses: money(total_amount: "2000", total_cadence: "monthly", total_source: "bills bout 2000 total",
      parts: [ part("add", "rent", "1500", source: "rent is 1500 of that") ]))))
    fixed = row(body, "fixed_expenses")
    assert_equal 200_000, fixed["total_cents"]
    assert_equal [ [ "Rent", 150_000 ], [ "Other must-pay bills", 50_000 ] ], fixed["parts"].map { |item| [ item["label"], item["cents"] ] }
    apply(card_of(body))
    assert_equal 2000.0, values[:fixed_expenses].to_f
    assert_equal [ "Rent", "Other must-pay bills" ], stack_names("non_discretionary")
  end

  test "a skipped goal doesn't keep the card closed to other fields" do
    say("Help me set up my household", read)
    say("skip", read(setup: changes(skips: [ "household_name" ])))
    say("skip", read(setup: changes(skips: [ "primary_goal" ])))
    body = say("4000 income, bills 1500, everyday 500, no debts", read(setup: changes(primary_income: money(total_amount: "4000", total_cadence: "monthly", total_source: "4000 income"),
      fixed_expenses: money(total_amount: "1500", total_cadence: "monthly", total_source: "bills 1500"), flexible_spend: money(total_amount: "500", total_cadence: "monthly", total_source: "everyday 500"),
      debt_payment: debts(none: true))))
    apply(card_of(body))
    assert_equal %w[household_name primary_goal], HouseholdFinance::SetupStatus.new(@household.reload).missing_field_keys
    fund = say("my emergency fund is 800", read(setup: changes(emergency_fund: { amount: "800", source: "my emergency fund is 800" })))
    assert_equal 80_000, row(fund, "emergency_fund")["total_cents"]
    sinking = say("i put away 50 a month for registration", read(setup: changes(expected_sinking_fund: money(parts: [ part("add", "registration", "50", source: "50 a month for registration") ]))))
    assert_equal [ "Registration" ], row(sinking, "expected_sinking_fund")["parts"].map { |item| item["label"] }
    apply(card_of(sinking))
    assert_equal 800.0, values[:emergency_fund].to_f
    assert_equal [ "Registration" ], stack_names("sinking_expected")
    assert_equal %w[household_name primary_goal], @household.reload.setup_skipped_fields.sort, "skipped stays skipped"
  end

  test "a form-only total keeps asking for a new total for a bill inside it, even beside a named bill" do
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Form", primary_goal: "steady", primary_income: "4800", fixed_expenses: "1900", flexible_spend: "500", credit_card_debt: "0", debt_payment: "0").call
    added = say("add phone 60", read(setup: changes(fixed_expenses: money(parts: [ part("add", "phone", "60", source: "add phone 60") ]))))
    apply(card_of(added))
    assert_equal [ "Fixed essentials", "Phone" ], stack_names("non_discretionary")
    body = say("the rent went up to 1700", read(setup: changes(fixed_expenses: money(parts: [ part("replace", "rent", "1700", source: "the rent went up to 1700") ]))))
    assert_nil card_of(body)
    assert_match(/I only have one total for fixed essentials \(\$1,900\), so I can't change rent by itself\. What should the new total be\?/, text(body))
    phone = say("the phone is 65 now", read(setup: changes(fixed_expenses: money(parts: [ part("replace", "phone", "65", source: "the phone is 65 now") ]))))
    assert_equal [ [ "Phone", 6_500 ] ], row(phone, "fixed_expenses")["parts"].map { |item| [ item["label"], item["cents"] ] }
  end

  test "after bills are split, a new overall total replaces them under a free name" do
    finish_setup
    @household.budget_categories.create!(name: "Fixed essentials", stack_key: "non_discretionary", active: false, sort_order: 99)
    body = say("my bills are like 2100 now", read(setup: changes(fixed_expenses: money(total_amount: "2100", total_cadence: "monthly", total_source: "my bills are like 2100 now"))))
    fixed = row(body, "fixed_expenses")
    assert_equal 210_000, fixed["total_cents"]
    assert_equal [ [ "Other must-pay bills", nil ], [ "Rent", true ], [ "Power", true ], [ "Insurance", true ] ], fixed["parts"].map { |item| [ item["label"], item["removed"] ] }
    apply(card_of(body))
    assert_equal 2100.0, values[:fixed_expenses].to_f
    assert_equal [ "Other must-pay bills" ], stack_names("non_discretionary")
  end

  test "a change the reader missed but the intent model found goes on the same card" do
    finish_setup
    intent = HouseholdFinance::MiaIntentResolver::Result.new(intent: "household_action", confidence: 0.9, continuation: false, resolved_message: "set emergency fund",
      needs_clarification: false, clarification: "", topic: {}, action: { type: "update_household_setup", setup_updates: { emergency_fund: "1200" } }, read_only_plan: {}, source: "model")
    body = say("my emergency fund is 1200 now", read, intent: intent)
    assert_equal 120_000, row(body, "emergency_fund")["total_cents"]
    assert_equal 1, @household.mia_action_drafts.pending.count, "no second review"

    invented = HouseholdFinance::MiaIntentResolver::Result.new(intent: "household_action", confidence: 0.9, continuation: false, resolved_message: "set emergency fund",
      needs_clarification: false, clarification: "", topic: {}, action: { type: "update_household_setup", setup_updates: { emergency_fund: "1500" } }, read_only_plan: {}, source: "model")
    guessed = say("put more in my emergency fund", read, intent: invented)
    assert_equal 120_000, row(guessed, "emergency_fund")["total_cents"], "a figure she never wrote never reaches the card"
    assert_match(/Tell me the new amount/, text(guessed))
  end

  test "a purchase mixed with a change gets both: the change card and the purchase to review" do
    finish_setup
    message = "spent 80 at payless, oh and power went up to 200"
    body = say(message, read(facts: [ { kind: "purchase", amount: "80", merchant: "payless", item: "", day: "", source_text: "spent 80 at payless" } ],
      setup: changes(fixed_expenses: money(parts: [ part("replace", "power", "200", source: "power went up to 200") ]))))
    assert_equal [ [ "Power", 20_000 ] ], row(body, "fixed_expenses")["parts"].map { |item| [ item["label"], item["cents"] ] }
    assert body["transaction_draft"], "the purchase is not dropped: #{text(body)}"
    assert_equal 8_000, body.dig("transaction_draft", "amount_cents")
    assert_match(/payless/i, body.dig("transaction_draft", "merchant").to_s)
    assert_match(/power/i, text(body))
    assert_match(/80/, text(body))
    assert_equal 1, @household.transaction_drafts.pending.count
    assert_equal 1, @household.mia_action_drafts.pending.count
  end

  def remove_bill(name, message)
    say(message, read(setup: changes(fixed_expenses: money(parts: [ part("remove", name, "", source: message) ]))))
  end

  test "taking off a bill that has a purchase waiting for review builds no card and says why" do
    finish_setup
    insurance = @household.budget_categories.find_by!(name: "Insurance")
    @household.transaction_drafts.create!(merchant: "Aflac", occurred_on: Date.current, total_amount_cents: 12_000, status: "pending", source_type: "manual_ui", budget_category: insurance)
    body = remove_bill("insurance", "we cancelled the insurance so take that off")
    assert_nil card_of(body), "no dead card"
    assert_equal 0, @household.mia_action_drafts.pending.count
    assert_match(/Insurance has a purchase waiting for your review.*Review that purchase first.*Nothing changed/, text(body))
    assert insurance.reload.active?
    @household.transaction_drafts.pending.update_all(status: "ignored")
    again = remove_bill("insurance", "ok now take insurance off")
    assert card_of(again), text(again)
  end

  test "adding a bill that shares a name with a row in another layer is a distinct row, and applies" do
    finish_setup
    HouseholdFinance::AnnualBudgetManager.new(@household.reload).create_category!(name: "Phone", stack_key: "discretionary", monthly_amount: "30")
    body = say("add phone 60", read(setup: changes(fixed_expenses: money(parts: [ part("add", "phone", "60", source: "add phone 60") ]))))
    assert card_of(body), text(body)
    assert_equal [ [ "Phone bill", 6_000 ] ], row(body, "fixed_expenses")["parts"].map { |item| [ item["label"], item["cents"] ] }
    assert_match(/Phone is already a row in your everyday spending, so I added this one as phone bill, \$60 a month/, text(body))
    apply(card_of(body))
    assert_equal %w[Rent Power Insurance] + [ "Phone bill" ], stack_names("non_discretionary")
    assert_equal [ "Phone" ], stack_names("discretionary").grep(/phone/i)
    assert_equal 2010.0, values[:fixed_expenses].to_f
    assert_equal 3_000, @household.budget_categories.find_by!(name: "Phone").budget_allocations.first.planned_amount_cents, "the everyday Phone row is untouched"
  end

  test "taking off a bill by a name that only exists in another layer touches nothing" do
    finish_setup
    HouseholdFinance::AnnualBudgetManager.new(@household.reload).create_category!(name: "Phone", stack_key: "discretionary", monthly_amount: "30")
    body = remove_bill("phone", "take off the phone")
    assert_nil card_of(body)
    assert_match(/I don't see phone/, text(body))
    assert @household.budget_categories.find_by!(name: "Phone").active?
  end

  test "adding back a bill she cancelled earlier is a new row under a clear name, applied from chat" do
    finish_setup
    apply(card_of(remove_bill("insurance", "we cancelled the insurance so take that off")))
    assert_equal %w[Rent Power], stack_names("non_discretionary")
    body = say("add insurance 130", read(setup: changes(fixed_expenses: money(parts: [ part("add", "insurance", "130", source: "add insurance 130") ]))))
    assert_match(/Insurance was taken off earlier and stays in your history, so I added this one as insurance bill, \$130 a month/, text(body))
    apply(card_of(body))
    assert_equal [ "Rent", "Power", "Insurance bill" ], stack_names("non_discretionary")
    assert_equal 1960.0, values[:fixed_expenses].to_f
    assert @household.budget_categories.archived.exists?(name: "Insurance"), "the old row keeps its history"
  end

  test "when both names are taken she is asked for another name and no card is built" do
    finish_setup
    apply(card_of(remove_bill("insurance", "we cancelled the insurance so take that off")))
    @household.budget_categories.create!(name: "Insurance bill", stack_key: "non_discretionary", active: false, sort_order: 99)
    body = say("add insurance 130", read(setup: changes(fixed_expenses: money(parts: [ part("add", "insurance", "130", source: "add insurance 130") ]))))
    assert_nil card_of(body)
    assert_match(/What should I call this new one\? Nothing changed\./, text(body))
  end

  test "a bill that is misrouted by the intent model as a plan change from a purchase report never replaces the bills" do
    finish_setup
    intent = HouseholdFinance::MiaIntentResolver::Result.new(intent: "household_action", confidence: 0.9, continuation: false, resolved_message: "set fixed expenses",
      needs_clarification: false, clarification: "", topic: {}, action: { type: "update_household_setup", setup_updates: { fixed_expenses: "120" } }, read_only_plan: {}, source: "model")
    body = say("paid 120 for the power bill today", read(facts: [ { kind: "purchase", amount: "120", merchant: "", item: "power bill", day: "today", source_text: "paid 120 for the power bill today" } ]), intent: intent)
    assert_nil card_of(body), "no plan change card: #{text(body)}"
    assert_equal 0, @household.mia_action_drafts.pending.count, "nothing proposed that replaces the bills"
    assert_equal 1950.0, values[:fixed_expenses].to_f
    assert_equal %w[Rent Power Insurance], stack_names("non_discretionary")
  end

  test "a payment the model labelled as a new bills total is not turned into one when bills are itemized" do
    finish_setup
    intent = HouseholdFinance::MiaIntentResolver::Result.new(intent: "household_action", confidence: 0.9, continuation: false, resolved_message: "set fixed expenses",
      needs_clarification: false, clarification: "", topic: {}, action: { type: "update_household_setup", setup_updates: { fixed_expenses: "60" } }, read_only_plan: {}, source: "model")
    body = say("i paid 60 for phone", read, intent: intent)
    assert_nil card_of(body), text(body)
    assert_match(/Tell me the new amount/, text(body))
    changed = say("my bills are 2100 now", read, intent: HouseholdFinance::MiaIntentResolver::Result.new(intent: "household_action", confidence: 0.9, continuation: false, resolved_message: "set fixed expenses",
      needs_clarification: false, clarification: "", topic: {}, action: { type: "update_household_setup", setup_updates: { fixed_expenses: "2100" } }, read_only_plan: {}, source: "model"))
    assert_equal 210_000, row(changed, "fixed_expenses")["total_cents"], "a stated change still reaches the card"
  end

  def model_intent(action, message) = HouseholdFinance::MiaIntentResolver::Result.new(intent: "household_action", confidence: 0.9, continuation: false, resolved_message: message,
    needs_clarification: false, clarification: "", topic: {}, action: action, read_only_plan: {}, source: "model")

  test "restoring a debt and switching debt tracking keep their own review, not a dead end" do
    finish_setup
    truck = @household.debts.find_by!(label: "Truck")
    truck.update!(active: false, archived_at: Time.current)
    restore = say("actually bring the truck back", read, intent: model_intent({ type: "restore_debt", debt_id: truck.id, debt_name: "Truck" }, "restore the truck"))
    assert_no_match(/Tell me the new amount/, text(restore))
    draft = restore["mia_action_draft"]
    assert draft, text(restore)
    assert_equal "debt_plan", draft["draft_type"]
    apply(draft)
    assert truck.reload.active?

    tracking = say("just track my debts as one total", read, intent: model_intent({ type: "update_debt_tracking", debt_tracking_mode: "summary", amount: "unknown", minimum_payment: "385" }, "track debts as one total"))
    assert_no_match(/Tell me the new amount/, text(tracking))
    assert tracking["mia_action_draft"], text(tracking)
    assert_equal "debt_plan", tracking["mia_action_draft"]["draft_type"]
  end

  test "weekly and twice-a-month pay after setup are offered as a month, and yes saves it" do
    finish_setup
    weekly = say("i get 1000 every week now", read(setup: changes(primary_income: money(total_amount: "1000", total_cadence: "weekly", total_source: "i get 1000 every week now"))))
    assert_match(/That's about \$4,333 a month \(1,000 × 52 ÷ 12\)\. Use \$4,333\?\z/, text(weekly))
    say("yes", read)
    assert_equal 433_300, rows(say("hold on", read))&.find { |item| item["key"] == "primary_income" }&.fetch("total_cents")
    twice = say("actually i get 1200 twice a month", read(setup: changes(primary_income: money(total_amount: "1200", total_cadence: "twice_monthly", total_source: "i get 1200 twice a month"))))
    assert_match(/\$2,400/, text(twice))
    yes = say("yes", read)
    assert_equal 240_000, row(yes, "primary_income")["total_cents"]
    apply(card_of(yes))
    assert_equal 2400.0, values[:primary_income].to_f
  end

  test "taking off every bill leaves fixed essentials at a stated zero on the card, and saves it" do
    finish_setup
    message = "we moved in with family so no more rent, power or insurance"
    body = say(message, read(setup: changes(fixed_expenses: money(parts: %w[rent power insurance].map { |name| part("remove", name, "", source: message) }))))
    assert card_of(body), text(body)
    fixed = row(body, "fixed_expenses")
    assert_equal 0, fixed["total_cents"], text(body)
    assert_equal [ true, true, true ], fixed["parts"].map { |item| item["removed"] }
    apply(card_of(body))
    assert_equal [], stack_names("non_discretionary")
    assert_equal 0.0, values[:fixed_expenses].to_f
  end

  test "care comes first on a completed household: a hardship message is not turned into a bill change" do
    finish_setup
    message = "my husband just lost his job and rent is due friday, its 1700 now"
    body = say(message, read(care: "hardship", setup: changes(fixed_expenses: money(parts: [ part("replace", "rent", "1700", source: "rent is due friday, its 1700 now") ]))))
    assert_nil card_of(body), "care replies take precedence over a change card"
    assert_match(/landlord|rent|payment arrangement|coach|trust/i, text(body))
    assert_equal 1950.0, values[:fixed_expenses].to_f
  end
end
