require "test_helper"

class ApiV1SetupCardTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "card_#{SecureRandom.hex(8)}", email: "card-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  EMPTY_MONEY = { none: false, total_amount: "", total_cadence: "", total_count: "", total_source: "", parts: [] }.freeze
  EMPTY_DEBT = { none: false, total_amount: "", total_source: "", parts: [] }.freeze

  def changes(**over)
    { household_name: "", primary_goal: "", primary_income: EMPTY_MONEY, fixed_expenses: EMPTY_MONEY, flexible_spend: EMPTY_MONEY,
      debt_payment: EMPTY_DEBT, skips: [], help_topic: "" }.merge(over)
  end

  def read(question: false, care: "none", facts: [], setup: changes)
    { care: care, facts: facts, question: question, care_status: "none", spending_preferences: [], setup_changes: setup }
  end

  def part(op, label, amount, cadence: "monthly", source: nil)
    { op: op, label: label, amount: amount, cadence: cadence, count: "", source: source || [ label, amount ].join(" ") }
  end

  def debt(op, name, minimum, balance = "", source: nil)
    { op: op, name: name, minimum: minimum, balance: balance, source: source || "" }
  end

  def money(**values) = EMPTY_MONEY.merge(values)
  def debts(**values) = EMPTY_DEBT.merge(values)

  def say(message, data, status: :created)
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    captured = nil
    klass.define_singleton_method(:call) do |**options|
      captured = options
      new(**options.merge(transport: ->(_payload) { JSON.generate(data) })).call
    end
    post "/api/v1/mia/messages", params: { message: message }, headers: auth, as: :json
    assert_response status
    @last_reader_options = captured
    response.parsed_body
  ensure
    klass.define_singleton_method(:call, original)
  end

  def auth = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def card_of(body) = body.dig("budget", "annual_plan", "pending_mia_action_drafts").to_a.find { |draft| draft["setup_card"] }

  def row(body, key) = card_of(body).dig("setup_card", "rows").find { |item| item["key"] == key }

  def apply(draft)
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply", params: {}, headers: auth.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    response.parsed_body
  end

  def last_reply = ChatMessage.where(role: "assistant").order(:id).last.content

  test "one card collects a hedged list, a removal and a correction in place" do
    first = say("rent 1000, power maybe 140 idk, water like 30, internet 85",
      read(setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1000"), part("add", "power", "140", source: "power maybe 140 idk"), part("add", "water", "30", source: "water like 30"), part("add", "internet", "85") ]))))
    card = card_of(first)
    assert_equal "Your setup so far", card["title"]
    assert_equal 125_500, row(first, "fixed_expenses")["total_cents"]
    assert_equal 4, row(first, "fixed_expenses")["parts"].length
    assert_match(/Added rent \$1,000, power \$140, water \$30, and internet \$85/, first.dig("assistant_message", "content"))
    assert_match(/Fixed essentials are \$1,255 so far/, first.dig("assistant_message", "content"))
    assert_equal "missing", row(first, "primary_income")["status"]
    assert_nil HouseholdFinance::SetupStatus.new(@household.reload).confirmed_field_keys.find { |key| key == "fixed_expenses" }

    second = say("take out the internet, landlord covers it now",
      read(setup: changes(fixed_expenses: money(parts: [ { op: "remove", label: "internet", amount: "", cadence: "", count: "", source: "take out the internet" } ]))))
    assert_equal card["id"], card_of(second)["id"]
    assert_equal 117_000, row(second, "fixed_expenses")["total_cents"]

    third = say("no the rent is 1350 not 1250",
      read(setup: changes(fixed_expenses: money(parts: [ part("replace", "rent", "1350", source: "the rent is 1350") ]))))
    assert_equal 152_000, row(third, "fixed_expenses")["total_cents"]
    assert_equal card["id"], card_of(third)["id"]
    assert_equal 1, @household.mia_action_drafts.pending.count
  end

  test "nothing saves before Apply and partial Apply leaves unknown unknown" do
    first = say("hi this is marie, camacho ohana. i bring home 3200", read(setup: changes(household_name: "camacho ohana", primary_income: money(total_amount: "3200", total_cadence: "monthly", total_source: "i bring home 3200"))))
    assert_equal "missing", row(first, "fixed_expenses")["status"]
    assert_equal [], HouseholdFinance::SetupStatus.new(@household.reload).confirmed_field_keys
    applied = apply(card_of(first))
    values = applied.dig("workspace", "workspace", "setup_values")
    assert_equal "camacho ohana", values["household_name"]
    assert_equal 3200.0, values["primary_income"].to_f
    status = HouseholdFinance::SetupStatus.new(@household.reload)
    assert_equal %w[primary_goal fixed_expenses flexible_spend debt_payment], status.missing_field_keys
    assert_not_includes last_reply, "complete"
    assert_match(/money to do/, last_reply)
  end

  test "two debts in one message become two rows and Apply creates both" do
    body = say("the visa is 75 n the truck is 310",
      read(setup: changes(debt_payment: debts(parts: [ debt("add", "visa", "75", source: "the visa is 75"), debt("add", "truck", "310", source: "the truck is 310") ]))))
    debt_row = row(body, "debt_payment")
    assert_equal %w[Visa Truck], debt_row["parts"].map { |item| item["label"] }
    assert_equal 38_500, debt_row["total_cents"]
    apply(card_of(body))
    active = @household.reload.debts.active
    assert_equal [ 7_500, 31_000 ], active.order(:minimum_payment_cents).pluck(:minimum_payment_cents)
    assert_includes HouseholdFinance::SetupStatus.new(@household).confirmed_field_keys, "debt_payment"
  end

  test "a balance never becomes a minimum and a debt without a minimum stays open" do
    body = say("visa balance is 4000", read(setup: changes(debt_payment: debts(parts: [ debt("add", "visa", "4000", "4000", source: "visa balance is 4000") ]))))
    debt_row = row(body, "debt_payment")
    assert_nil debt_row["parts"].first["cents"]
    assert_equal "needs a minimum", debt_row["parts"].first["note"]
    assert_equal "needs_monthly", debt_row["status"]
    assert_match(/monthly minimum on visa/i, body.dig("assistant_message", "content"))
  end

  test "skip sticks across Apply and is never asked again" do
    say("Help me set up my household", read)
    assert_match(/call your household/, last_reply)
    body = say("skip that one for now", read(setup: changes(skips: [ "household_name" ])))
    assert_match(/leave your household name for later/, body.dig("assistant_message", "content"))
    assert_match(/money to do/, body.dig("assistant_message", "content"))
    assert_equal [ "household_name" ], @household.reload.setup_skipped_fields
    second = say("we bring home 4000", read(setup: changes(primary_income: money(total_amount: "4000", total_cadence: "monthly", total_source: "we bring home 4000"))))
    assert_equal "skipped", row(second, "household_name")["status"]
    apply(card_of(second))
    assert_not_includes last_reply, "call your household"
    assert_match(/money to do/, last_reply)
  end

  test "setup complete is said only when debts are known and matches status" do
    body = say("ana here, get ahead, 4400 income, 2000 bills, 500 everyday", read(setup: changes(household_name: "ana", primary_goal: "get ahead",
      primary_income: money(total_amount: "4400", total_cadence: "monthly", total_source: "4400 income"),
      fixed_expenses: money(total_amount: "2000", total_cadence: "monthly", total_source: "2000 bills"),
      flexible_spend: money(total_amount: "500", total_cadence: "monthly", total_source: "500"))), status: :created) rescue flunk("setup message failed")
    apply(card_of(body))
    assert_not_includes last_reply, "complete"
    assert_match(/debts/i, last_reply)
    assert_includes HouseholdFinance::SetupStatus.new(@household.reload).missing_field_keys, "debt_payment"
    debt_turn = say("no debts", read(setup: changes(debt_payment: debts(none: true))))
    apply(card_of(debt_turn))
    assert_match(/Your household setup is complete/, last_reply)
    assert_equal [], HouseholdFinance::SetupStatus.new(@household.reload).missing_field_keys
  end

  test "non-monthly and range parts wait for a monthly amount and are not counted" do
    body = say("groceries 200 a week, gas 80",
      read(setup: changes(flexible_spend: money(parts: [ part("add", "groceries", "200", source: "groceries 200 a week"), part("add", "gas", "80") ]))))
    row_ = row(body, "flexible_spend")
    assert_equal "needs_monthly", row_["status"]
    assert_equal 8_000, row_["total_cents"]
    assert_equal "$200 a week", row_["parts"].first["note"]
    assert_not_includes card_of(body).fetch("items").flat_map { |item| item.dig("payload", "confirmed_fields").to_a }, "flexible_spend"
    edited = patch_card(card_of(body), field: "flexible_spend", action_name: "set", part_id: row_["parts"].first["id"], value: "860")
    updated = edited["mia_action_draft"]["setup_card"]["rows"].find { |item| item["key"] == "flexible_spend" }
    assert_equal "entered", updated["status"]
    assert_equal 94_000, updated["total_cents"]
  end

  test "a misbehaving reader cannot put a wrong number on the card" do
    [
      [ "rent 1000 power 200 so 1200 total", money(total_amount: "1200", total_cadence: "monthly", total_source: "1200 total", parts: [ part("add", "rent", "1000"), part("add", "power", "200") ]), 120_000 ],
      [ "rent 450-500", money(total_amount: "500", total_cadence: "monthly", total_source: "450-500"), nil ],
      [ "power is 20% of rent", money(parts: [ part("add", "power", "20", source: "power is 20%") ]), nil ],
      [ "we moved in 2024", money(parts: [ part("add", "move", "2024", source: "moved in 2024") ]), nil ],
      [ "rent due the 15", money(parts: [ part("add", "rent", "15", source: "rent due the 15") ]), nil ],
      [ "we got 3 kids", money(parts: [ part("add", "kids", "3", source: "got 3 kids") ]), nil ],
      [ "i dont pay 140 for water", money(parts: [ part("add", "water", "140", source: "pay 140") ]), nil ],
      [ "rent is 1350 not 1250", money(parts: [ part("add", "rent", "1250", source: "not 1250") ]), nil ],
      [ "gas 20 a week", money(parts: [ part("add", "gas", "20", source: "gas 20 a week") ]), nil ],
      [ "rent 1000 and i owe 4000 on the truck", money(parts: [ part("add", "rent", "1000"), part("add", "truck", "4000", source: "owe 4000 on the truck") ]), 100_000 ],
      [ "water 40 water 40", money(parts: [ part("add", "water", "40", source: "water 40"), part("add", "water", "40", source: "water 40"), part("add", "water", "40", source: "water 40") ]), 4_000 ]
    ].each do |message, field_change, expected|
      user = User.create!(clerk_id: "c#{SecureRandom.hex(6)}", email: "c#{SecureRandom.hex(6)}@example.invalid", role: "participant", invitation_status: "accepted")
      @user = user
      @household = HouseholdFinance::WorkspaceResolver.new(user).household
      body = say(message, read(setup: changes(fixed_expenses: field_change)))
      card = card_of(body)
      if expected
        assert_equal expected, row(body, "fixed_expenses")["total_cents"], message
      else
        assert_nil card && row(body, "fixed_expenses")["total_cents"], message
      end
    end
  end

  test "a question alongside a change answers and resumes" do
    say("Help me set up my household", read)
    body = say("rent is 1200, does power count", read(question: true, setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1200", source: "rent is 1200") ]))))
    assert_match(/\AAdded rent \$1,200/, body.dig("assistant_message", "content"))
    assert_equal 120_000, row(body, "fixed_expenses")["total_cents"]
    assert_equal "Your setup so far", card_of(body)["title"]
  end

  test "skipping the last open question ends setup without calling it complete" do
    save = { household_name: "Ana", primary_goal: "get ahead", primary_income: 4400, fixed_expenses: 2000, flexible_spend: 500 }
    HouseholdFinance::WorkspaceSetupSaver.new(@household, user: @user, attributes: save, idempotency_key: SecureRandom.uuid).call
    body = say("skip the debts", read(setup: changes(skips: [ "debt_payment" ])))
    assert_match(/later/, body.dig("assistant_message", "content"))
    assert_equal [ "debt_payment" ], @household.reload.setup_skipped_fields
    assert_equal "That's everything for now. Still to add when you're ready: debt minimums.", HouseholdFinance::MiaSetupGuide.new(@household).after_apply_message
  end

  test "care comes first and leaves the card untouched" do
    body = say("rent 1000", read(setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1000") ]))))
    before = card_of(body)
    say("my husband lost his job and rent is 1000", read(care: "hardship", setup: changes(fixed_expenses: money(parts: [ part("replace", "rent", "1000") ]))))
    draft = @household.mia_action_drafts.pending.sole
    assert_equal before["id"], draft.id
    assert_equal 1, draft.metadata.dig("setup_card", "fields", "fixed_expenses", "parts").length
  end

  test "reader failure writes nothing and points to Enter my numbers" do
    say("Help me set up my household", read)
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    klass.define_singleton_method(:call) { |**options| new(**options.merge(api_key: "", transport: nil)).call }
    post "/api/v1/mia/messages", params: { message: "rent 1500 power 200" }, headers: auth, as: :json
    assert_response :created
    assert_match(/Enter my numbers/, response.parsed_body.dig("assistant_message", "content"))
    assert_equal 0, @household.mia_action_drafts.count
  ensure
    klass.define_singleton_method(:call, original)
  end

  test "a help question is answered and setup resumes" do
    say("Help me set up my household", read)
    body = say("whats a household name", read(question: true, setup: changes(help_topic: "household_name")))
    assert_match(/label you choose/, body.dig("assistant_message", "content"))
    assert_match(/household plan|call your household/, body.dig("assistant_message", "content"))
  end

  test "reader context carries the card, skips and the last question" do
    say("Help me set up my household", read)
    say("skip", read(setup: changes(skips: [ "household_name" ])))
    say("get ahead", read(setup: changes(primary_goal: "get ahead")))
    context = @last_reader_options.fetch(:setup_context)
    assert_equal [ "household_name" ], context[:skipped]
    assert_equal "primary_goal", context[:last_asked]
    assert context[:draft].empty?
    say("3000", read(setup: changes(primary_income: money(total_amount: "3000", total_cadence: "monthly", total_source: "3000"))))
    assert @last_reader_options.fetch(:setup_context)[:draft].key?("primary_goal")
  end

  def patch_card(draft, **params)
    patch "/api/v1/mia_action_drafts/#{draft.fetch('id')}/setup_card", params: params, headers: auth, as: :json
    assert_response :success
    response.parsed_body
  end

  test "row edits and skip work on the card" do
    body = say("rent 1000", read(setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1000") ]))))
    card = card_of(body)
    result = patch_card(card, field: "household_name", action_name: "set", value: "  Camacho   Ohana ")
    row_ = result["mia_action_draft"]["setup_card"]["rows"].find { |item| item["key"] == "household_name" }
    assert_equal "Camacho Ohana", row_["value_text"]
    skip = patch_card(card, field: "primary_goal", action_name: "skip")
    assert_equal "skipped", skip["mia_action_draft"]["setup_card"]["rows"].find { |item| item["key"] == "primary_goal" }["status"]
    assert_equal [ "primary_goal" ], @household.reload.setup_skipped_fields
    patch "/api/v1/mia_action_drafts/#{card['id']}/setup_card", params: { field: "fixed_expenses", action_name: "set", part_id: "nope", value: "abc" }, headers: auth, as: :json
    assert_response :unprocessable_entity
  end
end
