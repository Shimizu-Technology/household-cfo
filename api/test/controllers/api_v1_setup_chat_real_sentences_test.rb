require "test_helper"

# Setup sentences shaped like the ones in a real-data test (Nov 18 2026), with
# invented names and amounts. The readings have the shape the live reader
# returned for the originals, so these pin the Ruby that turns a reading into
# the card and Mia's reply.
class ApiV1SetupChatRealSentencesTest < ActionDispatch::IntegrationTest
  EMPTY_MONEY = { none: false, total_amount: "", total_cadence: "", total_count: "", total_source: "", parts: [] }.freeze
  EMPTY_DEBT = { none: false, total_amount: "", total_source: "", parts: [] }.freeze
  EMPTY_BALANCE = { amount: "", source: "" }.freeze
  INCOME = "I take home about $4,800 a month from my job at the clinic, paid twice a month. I also get $400 a month from a side client (KTDS) and $120 from Tasi Tours."
  FAMILY_LOAN = "The surgery bill isn't a debt yet. It's a one-time bill coming next month, so please take it off debts. My real debt is a family loan from Tito Ben: I pay $300 a month and I'm about $900 behind. I'm not sure of the full balance."

  setup do
    @user = User.create!(clerk_id: "r9_#{SecureRandom.hex(8)}", email: "r9-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
    say("Help me set up my household. Please ask me one simple question at a time.", read)
  end
  teardown { ENV["OPENROUTER_API_KEY"] = @old_key }

  test "a monthly take-home paid twice a month is a month, not two paychecks of it" do
    body = say(INCOME, read(setup: changes(
      primary_income: money(total_amount: "4,800", total_cadence: "per_paycheck", total_count: "2", total_source: "I take home about $4,800 a month from my job at the clinic, paid twice a month."),
      business_income: money(parts: [ part("add", "KTDS", "400", source: "$400 a month from a side client (KTDS)"), part("add", "Tasi Tours", "120", source: "$120 from Tasi Tours") ]))))
    assert_equal 480_000, row(body, "primary_income")["total_cents"]
    assert_includes text(body), "Your income is $4,800 a month."
    assert_includes text(body), "Added KTDS $400 and Tasi Tours $120."
    refute_match(/9,600|not sure it's monthly|How often do you get that paycheck/, text(body))
  end

  test "twice a month with the monthly total named keeps the monthly total" do
    message = "Twice a month. $4,800 is the monthly total."
    body = say(message, read(setup: changes(primary_income: money(total_amount: "4,800", total_cadence: "monthly", total_count: "2", total_source: message))))
    assert_equal 480_000, row(body, "primary_income")["total_cents"]
    refute_match(/9,600|4,800 × 2/, text(body))
  end

  test "paychecks that make up the stated monthly total don't make the numbers disagree" do
    message = "No. Each paycheck is about $2,400. $4,800 is the total for the month."
    body = say(message, read(setup: changes(primary_income: money(total_amount: "4,800", total_cadence: "monthly", total_source: "$4,800 is the total for the month.",
      parts: [ { op: "add", label: "", amount: "2,400", cadence: "per_paycheck", count: "2", source: "Each paycheck is about $2,400." } ]))))
    assert_equal 480_000, row(body, "primary_income")["total_cents"]
    refute_match(/don't add up|not sure it's monthly/, text(body))
  end

  test "a family debt with the amount behind is put on the card, even when the reader hears hardship" do
    body = say(FAMILY_LOAN, read(care: "hardship", setup: changes(debt_payment: debts(parts: [
      debt("remove", "surgery bill", "", source: "The surgery bill isn't a debt yet. It's a one-time bill coming next month, so please take it off debts."),
      debt("add", "family loan from Tito Ben", "$300", source: "My real debt is a family loan from Tito Ben: I pay $300 a month and I'm about $900 behind. I'm not sure of the full balance.") ]))))
    assert_includes text(body), "Added family loan from Tito Ben $300."
    refute_match(/heavy week|solve the whole month/i, text(body))
    assert_equal [ "Family loan from Tito Ben" ], debt_names(body)
  end

  test "a feeling in the same message keeps the care reply" do
    message = "I'm so stressed. We owe Tito Ben and I'm about $900 behind. I pay $300 a month."
    body = say(message, read(care: "hardship", setup: changes(debt_payment: debts(parts: [ debt("add", "Tito Ben", "$300", source: "I pay $300 a month.") ]))))
    refute_includes text(body), "Added Tito Ben"
    message = "My husband just lost his job. I pay Tito Ben $300 a month and we're $900 behind."
    body = say(message, read(care: "hardship", setup: changes(debt_payment: debts(parts: [ debt("add", "Tito Ben", "$300", source: "I pay Tito Ben $300 a month") ]))))
    refute_includes text(body), "Added Tito Ben", "a life event keeps the care reply"
  end

  test "a one-time bill coming soon is not put in debts" do
    message = "Main goal: stop running short every month and build a cushion. There's also a one-time surgery bill of maybe $1,500-2,500."
    body = say(message, read(setup: changes(primary_goal: "stop running short every month and build a cushion",
      debt_payment: debts(parts: [ debt("add", "surgery bill", "$1,500", source: "a one-time surgery bill of maybe $1,500-2,500") ]))))
    assert_empty debt_names(body)
    assert_includes text(body), "Your goal is on the card."
  end

  test "a monthly total quoted without its dollar sign is still the month" do
    message = "My monthly total is $4,800, paid twice a month."
    body = say(message, read(setup: changes(primary_income: money(total_amount: "4,800", total_cadence: "per_paycheck", total_count: "2", total_source: message))))
    assert_equal 480_000, row(body, "primary_income")["total_cents"]
    refute_includes text(body), "9,600"
  end

  test "paychecks that don't add up to the stated total still ask" do
    message = "Our monthly total is $4,000. Lina gets two checks of $2,000 and Mateo gets two checks of $2,000."
    body = say(message, read(setup: changes(primary_income: money(total_amount: "4,000", total_cadence: "monthly", total_source: "Our monthly total is $4,000.",
      parts: [ { op: "add", label: "Lina", amount: "2,000", cadence: "per_paycheck", count: "2", source: "Lina gets two checks of $2,000" },
        { op: "add", label: "Mateo", amount: "2,000", cadence: "per_paycheck", count: "2", source: "Mateo gets two checks of $2,000" } ]))))
    assert_includes text(body), "those numbers don't add up"
  end

  test "distress beside a debt amount keeps the care reply" do
    [ "They laid me off Friday. Visa minimum is $75 a month.", "I was let go last week. Visa minimum is $75 a month.",
      "I've been out of work since August. Visa minimum is $75 a month.", "They cut my hours. Visa minimum is $75 a month.",
      "My husband left. I pay the Visa $75 a month.", "The bank is going to repo my car. Visa minimum is $75 a month.",
      "They're going to cut off our power on Friday. Visa minimum is $75 a month.", "Collections is garnishing my wages. Visa minimum is $75 a month.",
      "We're 2 months behind on rent, about $2,400. Visa minimum is $75 a month.", "My son is in the ICU. Visa minimum is $75 a month.",
      "We lost my dad last month. Visa minimum is $75 a month.", "I'm drowning in debt. Visa minimum is $75 a month.",
      "I pay the Visa $75 a month. My husband hasn't been home in three days.", "I pay the Visa $75 a month. What happens if they take us to court?" ].each do |message|
      body = say(message, read(care: "hardship", question: message.end_with?("?"), setup: changes(debt_payment: debts(parts: [ debt("add", "Visa", "$75", source: "$75 a month") ]))))
      refute_includes text(body), "Added Visa", message
    end
  end

  test "a paycheck count before the amount keeps it per paycheck" do
    message = "I get two checks of $2,400 a month."
    body = say(message, read(setup: changes(primary_income: money(total_amount: "2,400", total_cadence: "per_paycheck", total_count: "two", total_source: message))))
    assert_equal 480_000, row(body, "primary_income")["total_cents"]
  end

  test "only a bill she says is one-time or still to come leaves debts" do
    body = say("I also have a credit card bill I'm paying down.", read(setup: changes(debt_payment: debts(parts: [ debt("add", "credit card bill", "", source: "a credit card bill I'm paying down") ]))))
    assert_equal [ "Credit card bill" ], debt_names(body)
    body = say("There's a surgery bill coming next month, about $2,000.", read(setup: changes(debt_payment: debts(parts: [ debt("add", "surgery bill", "$2,000", source: "There's a surgery bill coming next month, about $2,000.") ]))))
    refute_includes debt_names(body), "Surgery bill"
  end

  test "an employer letting her go keeps the care reply" do
    message = "My employer let me go yesterday. My Visa minimum is $75 a month."
    body = say(message, read(care: "hardship", setup: changes(debt_payment: debts(parts: [ debt("add", "Visa", "$75", source: "My Visa minimum is $75 a month.") ]))))
    refute_includes text(body), "Added Visa"
  end

  test "a bill with a weekly payment stays a debt to clarify" do
    message = "My credit card bill is $50 weekly."
    body = say(message, read(setup: changes(debt_payment: debts(parts: [ debt("add", "credit card bill", "$50", source: message) ]))))
    assert_equal [ "Credit card bill" ], debt_names(body)
  end

  test "names keep the capitals she typed and the card's own rows read in lowercase" do
    reader = HouseholdFinance::ParticipantMessageReader::Current
    reader.message = "Fixed bills each month: rent to my aunt $1,600, water $150, Starlink $90, GTA phones $140. My debt is a family loan from Tito Ben."
    reply = HouseholdFinance::MiaSetupCardReply
    assert_equal "rent to my aunt", reply.inline("Rent to my aunt")
    assert_equal "water", reply.inline("Water")
    assert_equal "Starlink", reply.inline("Starlink")
    assert_equal "GTA phones", reply.inline("GTA phones")
    assert_equal "family loan from Tito Ben", reply.inline("Family loan from Tito Ben")
    assert_equal "bills", reply.inline("Bills")
    reader.message = "Starlink $85. Groceries and gas $600."
    assert_equal "Starlink", reply.inline("Starlink"), "a one-word name at the start of a sentence keeps its capital"
    assert_equal "groceries and gas", reply.inline("Groceries and gas")
    reader.message = nil
    assert_equal "KTDS", reply.inline("KTDS")
    assert_equal "eating out and coffee", reply.inline("Eating out and coffee")
  ensure
    reader&.reset
  end

  private

  def changes(**over)
    { household_name: "", primary_goal: "", primary_income: EMPTY_MONEY, business_income: EMPTY_MONEY, fixed_expenses: EMPTY_MONEY, flexible_spend: EMPTY_MONEY,
      expected_sinking_fund: EMPTY_MONEY, unexpected_sinking_fund: EMPTY_MONEY, emergency_fund: EMPTY_BALANCE, other_assets: EMPTY_BALANCE, credit_card_debt: EMPTY_BALANCE,
      debt_payment: EMPTY_DEBT, target_runway_months: { months: "", source: "" }, skips: [], help_topic: "", work_out: false, confirm_monthly: false }.merge(over)
  end

  def read(question: false, setup: changes, care: "none")
    { care: care, facts: [], question: question, care_status: "none", spending_preferences: [], setup_changes: setup }
  end

  def money(**values) = EMPTY_MONEY.merge(values)
  def debts(**values) = EMPTY_DEBT.merge(values)
  def part(op, label, amount, source:) = { op: op, label: label, amount: amount, cadence: "monthly", count: "", source: source }
  def debt(op, name, minimum, source:) = { op: op, name: name, minimum: minimum, balance: "", source: source }

  def say(message, data)
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    klass.define_singleton_method(:call) { |**options| new(**options.merge(transport: ->(_payload) { JSON.generate(data) })).call }
    post "/api/v1/mia/messages", params: { message: message }, headers: { "Authorization" => "Bearer test_token_#{@user.id}" }, as: :json
    assert_response :created
    response.parsed_body
  ensure
    klass.define_singleton_method(:call, original)
  end

  def text(body) = body.dig("assistant_message", "content")
  def card_of(body) = body.dig("budget", "annual_plan", "pending_mia_action_drafts").to_a.find { |draft| draft["setup_card"] }
  def row(body, key) = card_of(body).dig("setup_card", "rows").find { |item| item["key"] == key }
  def debt_names(body) = Array(card_of(body) && row(body, "debt_payment")&.fetch("parts", nil)).reject { |item| item["removed"] }.map { |item| item["label"] }
end
