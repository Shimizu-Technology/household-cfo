require "test_helper"
require_relative "../support/savings_challenge_test_support"

# Findings from final QA 5: care that wouldn't let setup resume, a closing line
# with nobody closing, one-bill changes after Apply, and setup loops.
class ApiV1FinalQaFiveTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport

  EMPTY_MONEY = { none: false, total_amount: "", total_cadence: "", total_count: "", total_source: "", parts: [] }.freeze
  EMPTY_DEBT = { none: false, total_amount: "", total_source: "", parts: [] }.freeze

  setup do
    @user = User.create!(clerk_id: "qa5_#{SecureRandom.hex(8)}", email: "qa5-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end
  teardown { ENV["OPENROUTER_API_KEY"] = @old_key }

  def changes(**over)
    { household_name: "", primary_goal: "", primary_income: EMPTY_MONEY, fixed_expenses: EMPTY_MONEY, flexible_spend: EMPTY_MONEY,
      debt_payment: EMPTY_DEBT, skips: [], help_topic: "", work_out: false, confirm_monthly: false }.merge(over)
  end

  def read(care: "none", care_status: "none", question: false, facts: [], setup: changes)
    { care: care, facts: facts, question: question, care_status: care_status, spending_preferences: [], setup_changes: setup }
  end

  def legacy(**values)
    { care: "none", care_status: "none", facts: [], question: false, correction: false, spending_preferences: [],
      setup_answer: { field: "none", value: "" }, setup_details: { field: "", cadence: "", count: "", partial: true, components: [], edit: { operation: "", item: "", amount: "", source: "" } } }.merge(values)
  end

  def part(op, label, amount, cadence: "monthly", source: nil)
    { op: op, label: label, amount: amount, cadence: cadence, count: "", source: source || [ label, amount ].join(" ") }
  end

  def money(**values) = EMPTY_MONEY.merge(values)
  def debts(**values) = EMPTY_DEBT.merge(values)
  def debt(name, minimum, source:) = { op: "add", name: name, minimum: minimum, balance: "", source: source }

  def auth
    { "Authorization" => "Bearer test_token_#{@user.id}" }.tap { |value| value["X-Cohort-Id"] = @savings_cohort.id.to_s if @savings_cohort }
  end

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

  def text(body) = body.dig("assistant_message", "content")
  def card_of(body) = body.dig("budget", "annual_plan", "pending_mia_action_drafts").to_a.find { |draft| draft["setup_card"] }
  def row(body, key) = card_of(body).dig("setup_card", "rows").find { |item| item["key"] == key }
  def session = @household.chat_sessions.order(:id).last
  def care_topic = session.active_topic.to_h["type"] == "care"

  def apply(draft)
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply", params: {}, headers: auth.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    response.parsed_body
  end

  def patch_card(draft, **params)
    patch "/api/v1/mia_action_drafts/#{draft.fetch('id')}/setup_card", params: params, headers: auth, as: :json
    assert_response :success
    response.parsed_body
  end

  def start_care
    say("Help me set up my household", read)
    say("sorry my husband just lost his job yesterday n rent is due friday its 1100, i dont know what were gonna do", read(care: "hardship", care_status: "none"))
    assert care_topic
  end

  # F1
  test "continuing setup after hardship releases care and the answer reaches the card" do
    start_care
    message = "ok lets keep goin w this, its only my check now, 2400 a month"
    body = say(message, read(care_status: "ongoing", setup: changes(primary_income: money(total_amount: "2400", total_cadence: "monthly", total_source: "its only my check now, 2400 a month"))))
    assert_not care_topic
    assert_equal 240_000, row(body, "primary_income")["total_cents"]
    assert_match(/Income: \$2,400 a month/, text(body))
    refute_match(/landlord/i, text(body))

    bills = "rent is 1100, power 150, phone 60. i dont have cable"
    body = say(bills, read(care_status: "ongoing", setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1100", source: "rent is 1100"), part("add", "power", "150"), part("add", "phone", "60") ]))))
    assert_equal 131_000, row(body, "fixed_expenses")["total_cents"]
  end

  test "named debts after hardship land on the card, with an unknown minimum kept" do
    start_care
    message = "theres the car 240 n a personal loan i dont know the min"
    body = say(message, read(care_status: "ongoing", setup: changes(debt_payment: debts(parts: [ debt("car", "240", source: "the car 240"), debt("personal loan", "", source: "a personal loan i dont know the min") ]))))
    assert_not care_topic
    debt_row = row(body, "debt_payment")
    assert_equal %w[Car Personal\ loan], debt_row["parts"].map { |item| item["label"] }
    assert_equal 24_000, debt_row["parts"].first["cents"]
    assert_nil debt_row["parts"].last["cents"]
    assert_match(/Added car \$240/, text(body))
    refute_match(/monthly minimum on personal loan/i, text(body), "she just said she doesn't know it")
    later = say("skip the groceries part i cant think rn", read(care_status: "ongoing", setup: changes(skips: [ "flexible_spend" ])))
    refute_match(/monthly minimum on personal loan/i, text(later))
    assert_equal "needs_monthly", row(later, "debt_payment")["status"]
    assert_match(/needs a minimum/, row(later, "debt_payment")["parts"].last["note"])
  end

  test "a skip during care is honoured and is not asked again" do
    say("Help me set up my household", read)
    say("I bring home 3000", read(setup: changes(primary_income: money(total_amount: "3000", total_cadence: "monthly", total_source: "I bring home 3000"))))
    say("sorry my husband just lost his job yesterday n rent is due friday its 1100", read(care: "hardship"))
    body = say("skip the groceries part i cant think rn", read(care_status: "ongoing", setup: changes(skips: [ "flexible_spend" ])))
    assert_not care_topic
    assert_equal [ "flexible_spend" ], @household.reload.setup_skipped_fields
    assert_match(/leave everyday spending for later/, text(body))
  end

  test "a skip is honoured even when the reader labels it hardship" do
    say("Help me set up my household", read)
    say("sorry my husband just lost his job yesterday n rent is due friday its 1100", read(care: "hardship"))
    body = say("skip the groceries part i cant think rn", read(care: "hardship", care_status: "ongoing", setup: changes(skips: [ "flexible_spend" ])))
    assert_not care_topic
    assert_equal [ "flexible_spend" ], @household.reload.setup_skipped_fields
    assert_match(/leave everyday spending for later/, text(body))
    refute_match(/food/i, text(body))
  end

  test "a skip with a new disclosure stays in care and skips nothing" do
    start_care
    say("skip it my husband left us last night", read(care: "hardship", care_status: "ongoing", setup: changes(skips: [ "primary_income" ])))
    assert care_topic
    assert_equal [], @household.reload.setup_skipped_fields
  end

  test "saying you want to carry on with nothing else asks the next question" do
    start_care
    body = say("ok lets keep going", read(care_status: "ongoing"))
    assert_not care_topic
    assert_match(/\?\z/, text(body))
    refute_match(/landlord|food/i, text(body))
  end

  test "an answer to a care question stays in care and writes nothing" do
    start_care
    body = say("we can do maybe 400 by friday", read(care_status: "ongoing"))
    assert care_topic
    assert_nil card_of(body)
    assert_equal 0, @household.mia_action_drafts.pending.count
  end

  test "a bare amount during care stays in care even if the reader read it as income" do
    start_care
    say("400", read(care_status: "ongoing", setup: changes(primary_income: money(total_amount: "400", total_cadence: "monthly", total_source: "400"))))
    assert care_topic
    assert_equal 0, @household.mia_action_drafts.pending.count
  end

  test "a new disclosure alongside setup words stays in care with the card untouched" do
    start_care
    say("my husband left us last night too, rent is 1100", read(care: "hardship", care_status: "ongoing", setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1100", source: "rent is 1100") ]))))
    assert care_topic
    assert_equal 0, @household.mia_action_drafts.pending.count
  end

  test "a crisis topic is not released by setup content" do
    say("Help me set up my household", read)
    say("i dont know if i can keep going, i dont want to be here", read(care: "crisis"))
    assert_equal "crisis", session.active_topic["care_kind"]
    say("ok lets keep going, 2400 a month", read(care_status: "ongoing", setup: changes(primary_income: money(total_amount: "2400", total_cadence: "monthly", total_source: "2400 a month"))))
    assert_equal "crisis", session.active_topic["care_kind"]
    assert_equal 0, @household.mia_action_drafts.pending.count
  end

  test "wanting to stop is never read as carrying on" do
    [ "i dont want to continue", "i cant keep going", "can we continue tomorrow", "i wanna go back home" ].each do |message|
      assert_not HouseholdFinance::ParticipantCare.setup_resume?(message), message
    end
    [ "ok lets keep goin w this", "can we pls finish the setup now", "lets continue", "ok lets get back to the setup" ].each do |message|
      assert HouseholdFinance::ParticipantCare.setup_resume?(message), message
    end
  end

  # F2
  test "a brush-off after a food disclosure stays in care and is not closed" do
    say("havent eaten today so the kids could, thats how it is this week", read(care: "hardship"))
    body = say("its fine im just tired", read(care_status: "resolved"))
    assert care_topic
    refute_match(/glad you have support|You're welcome/, text(body))
  end

  test "a goal with recovery is handled, not closed" do
    say("Help me set up my household", read)
    say("i dont want to be here", read(care: "crisis"))
    body = say("im ok now. goal is just to get caught up", read(care_status: "resolved", setup: changes(primary_goal: "just to get caught up")))
    refute_match(/You're welcome|glad you have support/, text(body))
    assert_equal "just to get caught up", row(body, "primary_goal")["value_text"]
  end

  test "the warm close keeps to what she actually said" do
    say("Help me set up my household", read)
    say("my mom died yesterday", read(care: "grief"))
    body = say("my cousin is helpin w the funeral now, thank you", read(care_status: "resolved"))
    assert_match(/glad you have support/, text(body))
    assert_match(/You're welcome/, text(body))
    assert_not care_topic

    say("my dad passed", read(care: "grief"))
    body = say("im doing better now", read(care_status: "resolved"))
    refute_match(/You're welcome|support/, text(body))
    assert_match(/settled|better/, text(body))
  end

  # F3
  def finish_setup
    body = say("taitano. get ahead. 5200 income. rent 1650 power 180 insurance 120. everyday 600. no debts", read(setup: changes(household_name: "taitano", primary_goal: "get ahead", primary_income: money(total_amount: "5200", total_cadence: "monthly", total_source: "5200 income"),
      fixed_expenses: money(parts: [ part("add", "rent", "1650"), part("add", "power", "180"), part("add", "insurance", "120") ]),
      flexible_spend: money(total_amount: "600", total_cadence: "monthly", total_source: "everyday 600"), debt_payment: debts(none: true))))
    apply(card_of(body))
    assert_equal [], HouseholdFinance::SetupStatus.new(@household.reload).missing_field_keys
  end

  # After setup the reader still fills the change card; a saved bill is named
  # by its saved label.
  def bill_edit(operation, item, amount, field: "fixed_expenses", source: nil)
    read(setup: changes(field.to_sym => money(parts: [ { op: operation, label: item, amount: amount, cadence: amount.empty? ? "" : "monthly", count: "", source: source || item } ])))
  end

  test "removing a saved bill after Apply reopens the breakdown on a new card" do
    finish_setup
    body = say("we cancelled the insurance so take that off", bill_edit("remove", "insurance", "", source: "we cancelled the insurance"))
    assert_includes @last_reader_options[:setup_context][:saved_bills]["fixed_expenses"], "Insurance $120"
    fixed = row(body, "fixed_expenses")
    assert_equal 183_000, fixed["total_cents"]
    assert_match(/Took out insurance/, text(body))
    assert_equal 195_000, HouseholdFinance::DataPresenter.new(@household.reload, ensure_plan: false).setup_values[:fixed_expenses].to_f * 100
    apply(card_of(body))
    assert_equal 1830.0, HouseholdFinance::DataPresenter.new(@household.reload, ensure_plan: false).setup_values[:fixed_expenses].to_f
  end

  test "changing a saved bill after Apply reopens the breakdown and a follow-up lands on the same card" do
    finish_setup
    body = say("oh n the rent went up to 1700", bill_edit("replace", "rent", "1700", source: "the rent went up to 1700"))
    assert_equal 200_000, row(body, "fixed_expenses")["total_cents"]
    assert_match(/Changed rent to \$1,700/, text(body))
    card = card_of(body)
    assert_nil row(body, "primary_income"), "only the changed row is on the card"

    second = say("we cancelled the insurance so take that off", read(setup: changes(fixed_expenses: money(parts: [ { op: "remove", label: "insurance", amount: "", cadence: "", count: "", source: "we cancelled the insurance" } ]))))
    assert_equal card["id"], card_of(second)["id"]
    assert_equal 188_000, row(second, "fixed_expenses")["total_cents"]
  end

  test "a breakdown survives a later card that only touched something else" do
    finish_setup
    body = say("the rent went up to 1700", bill_edit("replace", "rent", "1700", source: "the rent went up to 1700"))
    apply(card_of(body))
    assert_equal 2000.0, HouseholdFinance::DataPresenter.new(@household.reload, ensure_plan: false).setup_values[:fixed_expenses].to_f
    body = say("take the power off", bill_edit("remove", "power", "", source: "take the power off"))
    assert_equal 182_000, row(body, "fixed_expenses")["total_cents"]
  end

  test "a question alongside a bill change keeps the change in the reply" do
    finish_setup
    data = bill_edit("replace", "rent", "1700", source: "the rent went up to 1700").merge(question: true)
    narrator = HouseholdFinance::MiaNarrator
    original = narrator.instance_method(:call)
    narrator.define_method(:call) { "Your plan still has room." }
    begin
      body = say("the rent went up to 1700, how much is left now", data)
      assert_match(/Changed rent to \$1,700/, text(body))
      assert_equal 200_000, row(body, "fixed_expenses")["total_cents"]
    ensure
      narrator.define_method(:call, original)
    end
  end

  test "a form-only household can add a bill by chat on top of its saved total" do
    HouseholdFinance::SetupUpdater.new(@household, household_name: "Form Ohana", primary_goal: "steady", primary_income: "5200", fixed_expenses: "1950", flexible_spend: "600", credit_card_debt: "0", debt_payment: "0").call
    assert_equal [], HouseholdFinance::SetupStatus.new(@household.reload).missing_field_keys
    body = say("add phone 60", bill_edit("add", "phone", "60", source: "add phone 60"))
    fixed = row(body, "fixed_expenses")
    assert_equal 201_000, fixed["total_cents"]
    assert_equal [ "Phone" ], fixed["parts"].map { |part| part["label"] }
    assert_equal "Your changes", card_of(body)["title"]
    apply(card_of(body))
    assert_equal 2010.0, saved_fixed
    assert_equal [ "Fixed essentials", "Phone" ], @household.budget_categories.active.where(stack_key: "non_discretionary").order(:id).pluck(:name)
    assert_match(/Done: phone is \$60 and fixed essentials are \$2,010 a month\./, ChatMessage.where(role: "assistant").order(:id).last.content)
  end

  # F4
  test "a row edit moves the last-asked field to the next open one" do
    say("Help me set up my household", read)
    first = say("i get 1950 every 2 weeks after taxes", read(setup: changes(primary_income: money(total_amount: "1950", total_cadence: "biweekly", total_source: "i get 1950 every 2 weeks after taxes"))))
    assert_equal "primary_income", session.reload.active_topic["setup_card_field"]
    income = row(first, "primary_income")["parts"].first
    patch_card(card_of(first), field: "primary_income", action_name: "set", part_id: income["id"], value: "4225")
    assert_nil session.reload.active_topic["setup_card_field"], "the question she answered on the card is done"
    assert_equal "primary_income", session.reload.active_topic["setup_card_superseded"]

    # The reader puts the vague number on income; her own row wins and Mia asks.
    body = say("not sure, maybe 700 or 800", read(setup: changes(primary_income: money(total_amount: "800", total_cadence: "unclear", total_source: "maybe 700 or 800"))))
    assert_equal "", @last_reader_options[:setup_context][:last_asked]
    assert_equal 422_500, row(body, "primary_income")["total_cents"]
    assert_match(/You set income to \$4,225 on the card, so I kept it\. What's the \$700 to \$800 for, your household name or something else\?/, text(body))

    # Placed on everyday spending instead, it becomes one plain offer.
    spending = say("everyday is maybe 700 or 800", read(setup: changes(flexible_spend: money(total_amount: "800", total_cadence: "unclear", total_source: "maybe 700 or 800"))))
    assert_equal 422_500, row(spending, "primary_income")["total_cents"]
    assert_match(/Want to use \$750 for now\? You can change it any time\./, text(spending))
    yes = say("yes", read(setup: changes))
    assert_equal 75_000, row(yes, "flexible_spend")["total_cents"]
  end

  test "a database error while advancing the question keeps the row edit" do
    say("Help me set up my household", read)
    first = say("i get 1950 every 2 weeks after taxes", read(setup: changes(primary_income: money(total_amount: "1950", total_cadence: "biweekly", total_source: "i get 1950 every 2 weeks after taxes"))))
    income = row(first, "primary_income")["parts"].first
    original = ChatSession.instance_method(:update!)
    ChatSession.define_method(:update!) do |*args, **kwargs|
      # A real database error, which aborts the surrounding transaction.
      self.class.connection.execute("SELECT 1/0") if kwargs.key?(:active_topic) || args.first.to_h.key?(:active_topic)
      original.bind_call(self, *args, **kwargs)
    end
    begin
      patch_card(card_of(first), field: "primary_income", action_name: "set", part_id: income["id"], value: "4225")
    ensure
      ChatSession.define_method(:update!, original)
    end
    draft = MiaActionDraft.find(card_of(first)["id"])
    assert_equal 422_500, draft.metadata.dig("setup_card", "fields", "primary_income", "parts", 0, "cents")
  end

  test "an edit to a different row leaves the open question alone" do
    say("Help me set up my household", read)
    first = say("we are the reyes, rent 1000", read(setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1000") ]))))
    asked = session.reload.active_topic["setup_card_field"]
    patch_card(card_of(first), field: "primary_goal", action_name: "skip")
    assert_equal asked, session.reload.active_topic["setup_card_field"]
  end

  # F5
  def biweekly_income
    say("Help me set up my household", read)
    say("i get 1950 every 2 weeks after taxes", read(setup: changes(primary_income: money(total_amount: "1950", total_cadence: "biweekly", total_source: "i get 1950 every 2 weeks after taxes"))))
  end

  test "asking for help shows the working, needs confirmation, and a yes uses it" do
    biweekly_income
    body = say("yeah help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    assert_match(/\$1,950/, text(body))
    assert_match(/26/, text(body))
    assert_match(/\$4,225/, text(body))
    income = row(body, "primary_income")
    assert_equal "needs_monthly", income["status"]
    assert_nil income["total_cents"]
    assert_match(/\$4,225/, income["parts"].first["note"])
    assert_equal 1, text(body).count("?")

    yes = say("yeah use that", read(setup: changes(confirm_monthly: true)))
    confirmed = row(yes, "primary_income")
    assert_equal "entered", confirmed["status"]
    assert_equal 422_500, confirmed["total_cents"]
  end

  test "a plain yes with no reader flag confirms the working, and a number replaces it" do
    biweekly_income
    say("yeah help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    yes = say("yep", read(setup: changes))
    assert_equal 422_500, row(yes, "primary_income")["total_cents"]
  end

  test "the same question is not asked again when she cannot answer it" do
    biweekly_income
    body = say("idk how to figure that out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    refute_match(/I only have it as/, text(body))
    assert_match(/\$1,950 × 26 = \$50,700 a year/, text(body))
    # Moving past the offer twice parks it instead of asking a third time.
    parked = say("hmm", read(setup: changes))
    assert_match(/I'll leave income as \$1,950 every two weeks for now/, text(parked))
    refute_match(/Use \$4,225\?/, text(parked))
    assert_equal "needs_monthly", row(parked, "primary_income")["status"]
  end

  test "pay every two weeks is one question with the monthly figure" do
    biweekly_income
    body = ChatMessage.where(role: "assistant").order(:id).last.content
    assert_match(/That's about \$4,225 a month \(1,950 × 26 ÷ 12\)\. Use \$4,225\?\z/, body)
    assert_equal 1, body.count("?")
    number = say("its 4300", income_read("4300", "monthly", "its 4300"))
    assert_equal 430_000, row(number, "primary_income")["total_cents"]
  end

  test "with nothing to work from Mia asks the amount and how often first" do
    say("Help me set up my household", read)
    say("hi", read(setup: changes))
    body = say("help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    assert_match(/paycheck/i, text(body))
    assert_match(/how often/i, text(body))

    amount = say("1950", read(setup: changes(primary_income: money(total_amount: "1950", total_cadence: "monthly", total_source: "1950"))))
    assert_nil row(amount, "primary_income")["total_cents"], "a paycheck is not a month"
    assert_match(/how often/i, text(amount))

    how_often = say("every 2 weeks", read(setup: changes))
    assert_match(/\$4,225/, text(how_often))
    assert_equal "needs_monthly", row(how_often, "primary_income")["status"]
  end

  test "twice a month after a paycheck amount is counted, and paychecks are not a lone amount" do
    say("Help me set up my household", read)
    say("hi", read(setup: changes))
    say("help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    say("1950", read(setup: changes(primary_income: money(total_amount: "1950", total_cadence: "monthly", total_source: "1950"))))
    body = say("twice a month", read(setup: changes))
    assert_nil row(body, "primary_income")["total_cents"]
    assert_match(/That's \$3,900 a month \(1,950 × 2\)\. Use \$3,900\?/, text(body))
    assert_nil session.reload.active_topic["setup_card_work_out"]
    assert_equal 390_000, row(say("yes", read(setup: changes)), "primary_income")["total_cents"]

    @user = User.create!(clerk_id: "qa5b_#{SecureRandom.hex(8)}", email: "qa5b-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    say("Help me set up my household", read)
    say("hi", read(setup: changes))
    say("help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    counted = say("2 paychecks of 1400", read(setup: changes(primary_income: money(total_amount: "1400", total_cadence: "per_paycheck", total_count: "2", total_source: "2 paychecks of 1400"))))
    assert_equal 280_000, row(counted, "primary_income")["total_cents"]
  end

  test "a yes only confirms the figure Mia just asked about" do
    biweekly_income
    offered = say("yeah help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    assert_equal "primary_income", session.reload.active_topic["setup_card_field"]
    session.update!(active_topic: session.active_topic.merge("setup_card_field" => "fixed_expenses"))
    later = say("yes", read(setup: changes))
    assert_equal "needs_monthly", row(later, "primary_income")["status"], offered.dig("assistant_message", "content")
  end

  test "weekly help uses the year, not four weeks" do
    say("Help me set up my household", read)
    say("i get 800 a week", read(setup: changes(primary_income: money(total_amount: "800", total_cadence: "weekly", total_source: "i get 800 a week"))))
    body = say("help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    assert_match(/52/, text(body))
    assert_match(/\$3,467/, text(body))
  end

  test "a definition question still gets the definition" do
    say("Help me set up my household", read)
    say("i get 1950 every 2 weeks", read(setup: changes(primary_income: money(total_amount: "1950", total_cadence: "biweekly", total_source: "i get 1950 every 2 weeks"))))
    body = say("whats take home mean", read(setup: changes(help_topic: "primary_income")))
    assert_match(/after taxes/, text(body))
    assert_equal 1, text(body).scan("Use $4,225?").length
  end

  test "skipping an unresolved row stops asking about it" do
    biweekly_income
    body = say("skip that for now", read(setup: changes(skips: [ "primary_income" ])))
    refute_match(/I only have it as/, text(body))
    assert_includes @household.reload.setup_skipped_fields, "primary_income"
  end

  # F14
  test "a real question about the challenge after grief gets a real answer" do
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @user, @household = @savings_user, @savings_household
    say("my dad passed friday n the rosary n food is gonna be like 900, im not sure im up for this challenge rn", legacy(care: "grief"))
    body = say("how do i pause the challenge tho", legacy(care_status: "ongoing", question: true))
    assert_match(/isn't a pause|can't pause/i, text(body))
    assert_match(/program team/i, text(body))
    refute_match(/Start with one purchase/, text(body))
    assert_not care_topic
  end

  test "asking to leave the challenge gets a plain answer, and an ordinary question does not" do
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @user, @household = @savings_user, @savings_household
    body = say("how do i quit this challenge", legacy(question: true))
    assert_match(/program team/i, text(body))
    other = say("how much did i save so far", legacy(question: true))
    refute_match(/program team/i, text(other))
    assert_nil SavingsChallenge::ParticipantHelp.answer("how do i stop overspending during the challenge")
    assert SavingsChallenge::ParticipantHelp.answer("how do i take a pause from the challenge tho")
  end

  # Minors
  test "a monthly payment is never read as a purchase price" do
    reading = HouseholdFinance::ParticipantMessageReader.call(message: "hey should i finance a new iphone, 45 a month, money tight",
      transport: ->(_) { legacy(question: true, reply_intent: "purchase_caution", purchase_question: { amount: "45", item: "iphone" }).to_json })
    assert_equal "", reading.purchase_question["amount"]
    assert_equal "iphone", reading.purchase_question["item"]
  end

  test "a financed phone is not answered as a forty-five dollar purchase" do
    finish_setup
    body = say("hey should i finance a new iphone, 45 a month, money tight", legacy(question: true, reply_intent: "purchase_caution", purchase_question: { amount: "45", item: "iphone" }))
    refute_match(/\$45(?:\.00)? (?:new )?iphone/i, text(body))
    refute_match(/would leave/, text(body))
    assert_match(/full price/, text(body))
    assert_equal 1, text(body).count("?")
  end

  test "income quoted by the month is not a monthly payment" do
    assert_not HouseholdFinance::MiaCoachAnswerer.monthly_payment_question?("I make $4,500 a month. Can I afford a stroller?")
    assert HouseholdFinance::MiaCoachAnswerer.monthly_payment_question?("should i finance a new iphone, 45 a month")
  end

  test "dollars or bucks a month also gets the full price question" do
    finish_setup
    [ "should i finance a new iphone, 45 bucks a month", "should i finance a new iphone, 45 dollars a month" ].each do |message|
      body = say(message, legacy(question: true, reply_intent: "purchase_caution", purchase_question: { amount: "45", item: "iphone" }))
      assert_match(/full price/, text(body), message)
    end
  end

  test "a payment worded before the amount, or beside income, is still a payment" do
    [ [ "Can I buy a phone with a monthly payment of $45?", "phone" ], [ "My salary is $3,000. Can I buy a TV with payments of $45 a month?", "TV" ],
      [ "should i finance a new iphone 15, 45 a month", "iphone" ] ].each do |message, item|
      assert HouseholdFinance::MiaCoachAnswerer.monthly_payment_question?(message), message
      reading = HouseholdFinance::ParticipantMessageReader.call(message: message,
        transport: ->(_) { legacy(question: true, purchase_question: { amount: "45", item: item }).to_json })
      assert_equal "", reading.purchase_question["amount"], message
    end
  end

  test "income in a comma clause and a payment term are read for what they are" do
    assert_not HouseholdFinance::MiaCoachAnswerer.monthly_payment_question?("Can I buy a TV, I make $3,000 a month?")
    assert_empty HouseholdFinance::PurchaseQuestionText.payment_cents("Can I buy a TV, I make $3,000 a month?")
    message = "Can I buy a TV with payments of $45 for 12 months?"
    assert_equal [ 4500 ], HouseholdFinance::PurchaseQuestionText.payment_cents(message)
    assert HouseholdFinance::MiaCoachAnswerer.monthly_payment_question?(message)
  end

  test "a bill paid twice a month counts both payments" do
    say("Help me set up my household", read)
    body = say("groceries 150 twice a month", read(setup: changes(flexible_spend: money(parts: [ part("add", "groceries", "150", source: "groceries 150 twice a month") ]))))
    flexible = row(body, "flexible_spend")
    assert_equal 30_000, flexible["total_cents"]
    assert_match(/\$150 twice a month/, flexible["parts"].first["note"].to_s)
  end

  test "a stated full price stays comparable next to a payment" do
    message = "Could I buy a $1,000 TV with payments of $45 a month?"
    assert_not HouseholdFinance::MiaCoachAnswerer.monthly_payment_question?(message)
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message,
      transport: ->(_) { legacy(question: true, purchase_question: { amount: "1,000", item: "TV" }).to_json })
    assert_equal "1,000", reading.purchase_question["amount"]
    finish_setup
    body = say(message, legacy(question: true, reply_intent: "purchase_question", purchase_question: { amount: "1,000", item: "TV" }))
    refute_match(/full price/, text(body))
    assert_match(/\$1,000/, text(body))
  end

  test "an amount is a payment only where every mention of it is one" do
    [ [ "I make $4,500 a month. Can I afford a $4,500 stroller?", "4,500", "stroller" ], [ "should i finance a phone for 450, 45 a month", "450", "phone" ] ].each do |message, amount, item|
      reading = HouseholdFinance::ParticipantMessageReader.call(message: message,
        transport: ->(_) { legacy(question: true, purchase_question: { amount: amount, item: item }).to_json })
      assert_equal amount, reading.purchase_question["amount"], message
    end
  end

  test "a one-off price stays a price" do
    reading = HouseholdFinance::ParticipantMessageReader.call(message: "can i get a 650 tv on the card",
      transport: ->(_) { legacy(question: true, purchase_question: { amount: "650", item: "tv" }).to_json })
    assert_equal "650", reading.purchase_question["amount"]
  end

  test "a purchase mentioned during setup gets a review card and is not waved through" do
    say("Help me set up my household", read)
    message = "just got back from payless spent like 80 on food"
    body = say(message, read(facts: [ { kind: "purchase", amount: "80", merchant: "payless", item: "food", day: "", source_text: "spent like 80 on food" } ]))
    refute_match(/Take your time/, text(body))
    assert_not_nil body["transaction_draft"]
    assert_equal 8000, body.dig("transaction_draft", "amount_cents")
  end

  test "saying keep going does not swallow a purchase in the same message" do
    start_care
    message = "ok lets keep going, i spent 80 at payless"
    body = say(message, read(care_status: "ongoing", facts: [ { kind: "purchase", amount: "80", merchant: "payless", item: "", day: "", source_text: "i spent 80 at payless" } ]))
    refute_equal HouseholdFinance::MiaSetupCardTurn::RESUMED, text(body)
    assert_equal 8000, body.dig("transaction_draft", "amount_cents")
  end

  test "a debt named only in a question is not added" do
    message = "does my car loan count as a debt?"
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, setup_context: { saved: {}, draft: {}, skipped: [], last_asked: "debt_payment" },
      transport: ->(_) { read(question: true, setup: changes(debt_payment: debts(parts: [ debt("car loan", "", source: "my car loan") ]))).to_json })
    assert_not_nil reading.setup_changes
    assert_empty Array(reading.setup_changes.to_h.dig("debt_payment", "parts"))
  end

  test "a payment that hasn't gone through outside the app is not an unbacked change claim" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "my rent payment hasnt gone through", answer_packet: { kind: "coaching", write_state: "no_write", fallback_response: "fallback" }, api_key: "")
    [ "If your rent payment hasn't gone through by Friday, call your landlord.", "Your rent payment is pending; if it hasn't gone through, call your landlord." ].each do |reply|
      assert_nil narrator.send(:narration_rejection_reason, reply), reply
    end
  end

  test "a saving reported with a question about quitting is not answered as only the quit question" do
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @user, @household = @savings_user, @savings_household
    body = say("I put $50 aside today, how do i quit the challenge?", legacy(question: true, facts: [ { kind: "set_aside", amount: "50", merchant: "", item: "", day: "", source_text: "I put $50 aside today" } ]))
    refute_equal SavingsChallenge::ParticipantHelp::ANSWER, text(body)
    assert_equal 5000, body.dig("savings_intake", "amount_cents")
  end

  test "one reply never carries two questions" do
    say("Help me set up my household", read)
    narrator = HouseholdFinance::MiaNarrator
    original = narrator.instance_method(:call)
    narrator.define_method(:call) { "Good question. Which sounds closer to you?" }
    begin
      body = say("how much should i save tho", read(question: true))
      assert_equal 1, text(body).count("?"), text(body)
    ensure
      narrator.define_method(:call, original)
    end
  end

  test "participant is never used to address her" do
    packet = { kind: "coaching", write_state: "no_write", fallback_response: "fallback" }
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "idk", answer_packet: packet, api_key: "")
    assert_equal "That's okay, not knowing yet is a real answer.", narrator.send(:sanitize_narration, "That's okay, participant, not knowing yet is a real answer.")
  end

  test "unbacked change claims are rejected on a no-write turn" do
    packet = { kind: "coaching", write_state: "no_write", fallback_response: "fallback" }
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "x", answer_packet: packet, api_key: "")
    [ "Thanks for adding the car and the personal loan.", "Your saved plan still has insurance, so that change hasn't gone through yet.", "You didn't answer about food earlier, so I'm asking again." ].each do |claim|
      assert_equal :unbacked_change_claim, narrator.send(:narration_rejection_reason, claim), claim
    end
    assert_nil narrator.send(:narration_rejection_reason, "Thanks for telling me that.")
    without_state = HouseholdFinance::MiaNarrator.new(user_message: "x", answer_packet: { kind: "budget_action", fallback_response: "fallback" }, api_key: "")
    assert_equal :unbacked_change_claim, without_state.send(:narration_rejection_reason, "That change hasn't gone through yet.")
  end

  test "a merchant from another clause is still refused when two amounts are in play" do
    message = "spent 12 on lunch at kin and 40 on gas"
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message,
      transport: ->(_) { legacy(facts: [ { kind: "purchase", amount: "40", merchant: "kin", item: "gas", day: "", source_text: "40 on gas" } ]).to_json })
    assert_empty reading.facts
  end

  test "reviewed spending totals use commas" do
    answer = SpendingPatterns::Answerer.allocate
    assert_equal "$2,246.66", answer.send(:money, 224_666)
    assert_equal "$150", answer.send(:money, 15_000)
  end

  test "a reused review card says so in plain words" do
    body = say("rent 1000", read(setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1000") ]))))
    apply(card_of(body))
    draft = @household.mia_action_drafts.find(card_of(body)["id"])
    result = HouseholdFinance::MiaActionDraftApplier.new(draft, user: @user).call(idempotency_key: SecureRandom.uuid)
    assert_not result.success?
    assert_no_match(/Mia action draft/, result.errors.join)
    assert_match(/review card/i, result.errors.join)
  end

  # Independent review of #273
  def fresh_user
    @user = User.create!(clerk_id: "qa5r_#{SecureRandom.hex(8)}", email: "qa5r-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
  end

  def saved_fixed = HouseholdFinance::DataPresenter.new(@household.reload, ensure_plan: false).setup_values[:fixed_expenses].to_f

  def finish_with_lump_total
    body = say("taitano. get ahead. 5200 income. bills about 1950. everyday 600. no debts", read(setup: changes(household_name: "taitano", primary_goal: "get ahead", primary_income: money(total_amount: "5200", total_cadence: "monthly", total_source: "5200 income"),
      fixed_expenses: money(total_amount: "1950", total_cadence: "monthly", total_source: "bills about 1950"),
      flexible_spend: money(total_amount: "600", total_cadence: "monthly", total_source: "everyday 600"), debt_payment: debts(none: true))))
    apply(card_of(body))
  end

  test "a named bill after a saved lump total asks for the new total and never adds to it" do
    finish_with_lump_total
    body = say("oh n the rent went up to 1700", bill_edit("replace", "rent", "1700", source: "the rent went up to 1700"))
    assert_nil card_of(body)
    assert_match(/What should the new total be\?/, text(body))
    assert_equal 1950.0, saved_fixed
    assert_equal 0, @household.mia_action_drafts.pending.count
    body = say("take that insurance off", bill_edit("remove", "insurance", "", source: "take that insurance off"))
    assert_match(/What should the new total be\?/, text(body))
    refute_match(/tap Apply|Look over your card/, text(body))
  end

  [ [ "replace", "rent went up" ], [ "add", "rent went up" ] ].each do |op, label|
    test "on an open card a lump total is not added to (#{op}, #{label})" do
      say("Help me set up my household", read)
      say("bills about 1950", read(setup: changes(fixed_expenses: money(total_amount: "1950", total_cadence: "monthly", total_source: "bills about 1950"))))
      body = say("oh n the rent went up to 1700", read(setup: changes(fixed_expenses: money(parts: [ part(op, "rent", "1700", source: "the rent went up to 1700") ]))))
      fixed = row(body, "fixed_expenses")
      assert_equal 195_000, fixed["total_cents"], text(body)
      assert_match(/What should the new total be\?/, text(body))
    end
  end

  test "a lump total carried after a partial Apply is not added to" do
    say("Help me set up my household", read)
    first = say("bills about 1950", read(setup: changes(fixed_expenses: money(total_amount: "1950", total_cadence: "monthly", total_source: "bills about 1950"))))
    apply(card_of(first))
    body = say("oh n the rent went up to 1700", read(setup: changes(fixed_expenses: money(parts: [ part("replace", "rent", "1700", source: "the rent went up to 1700") ]))))
    assert_match(/What should the new total be\?/, text(body))
    assert_equal 0, @household.mia_action_drafts.pending.count
    assert_equal 1950.0, saved_fixed
  end

  test "a bill that is not on her saved list is not described as being on a card" do
    finish_setup
    body = say("take the cable off", bill_edit("remove", "cable", "", source: "take the cable off"))
    assert_nil card_of(body)
    refute_match(/your card|tap Apply/i, text(body))
    assert_match(/cable/i, text(body))
    assert_equal 0, @household.mia_action_drafts.pending.count
  end

  FINDING_TWO = [
    "skip it we cant eat this week", "skip that the kids havent eaten", "skip it landlord wants us out by friday", "skip rent we cant pay it",
    "skip power they cut us off yesterday", "skip it im gonna lose the house", "skip it he took all our money", "skip it i cant do this anymore", "skip it i dont want to be here anymore"
  ].freeze

  FINDING_TWO.each do |message|
    [ %w[hardship ongoing], %w[none new_topic] ].each do |care, status|
      test "#{message} keeps care or reaches 988 when read as #{care}" do
        start_care
        body = say(message, read(care: care, care_status: status, setup: changes(skips: [ "flexible_spend" ])))
        assert care_topic || text(body).include?("988"), text(body)
        assert_empty @household.reload.setup_skipped_fields
        assert_equal 0, @household.mia_action_drafts.pending.count
      end
    end
  end

  def skip_reading(message, care: "hardship")
    HouseholdFinance::ParticipantMessageReader.call(message: message, setup_context: { saved: {}, draft: {}, skipped: [], last_asked: "flexible_spend" },
      transport: ->(_) { read(care: care, care_status: "ongoing", setup: changes(skips: [ "flexible_spend" ])).to_json })
  end

  test "only plain skip wording overrides a hardship label" do
    [ "skip", "skip it", "skip that for now", "later", "not now", "i cant think rn", "skip the groceries part i cant think rn", "skip rent", "ok skip this one" ].each do |message|
      assert HouseholdFinance::ParticipantCare.skip_only?(message, skip_reading(message)), message
    end
    (FINDING_TWO + [ "skip it im so tired of everything", "later i guess theres no point" ]).each do |message|
      assert_not HouseholdFinance::ParticipantCare.skip_only?(message, skip_reading(message)), message
    end
    assert_not HouseholdFinance::ParticipantCare.skip_only?("skip", skip_reading("skip", care: "crisis"))
  end

  test "crisis wording is never read as a skip" do
    [ "skip it i dont want to be here anymore", "skip it i cant do this anymore" ].each do |message|
      assert ::Mia::CrisisBoundary.soft?(message) || ::Mia::CrisisBoundary.matches?(message), message
      assert_not HouseholdFinance::ParticipantCare.skip_only?(message, skip_reading(message)), message
    end
    start_care
    body = say("skip it i dont want to be here anymore", read(care: "crisis", setup: changes(skips: [ "flexible_spend" ])))
    assert_includes text(body), "988"
    assert_empty @household.reload.setup_skipped_fields
  end

  [ "ok lets keep goin i have nothing left", "ok lets keep goin the kids havent eaten since yesterday", "rent is 1100 n i still dont know how we gonna pay it" ].each do |message|
    test "a current hardship sign does not release care: #{message}" do
      start_care
      setup = message.start_with?("rent") ? changes(fixed_expenses: money(parts: [ part("add", "rent", "1100", source: "rent is 1100") ])) : changes
      say(message, read(care_status: "new_topic", setup: setup))
      assert care_topic
      assert_equal 0, @household.mia_action_drafts.pending.count
    end
  end

  def income_read(amount, cadence, source, count: "")
    read(setup: changes(primary_income: money(total_amount: amount, total_cadence: cadence, total_count: count, total_source: source)))
  end

  [ [ "i get 1950 per paycheck", "biweekly" ], [ "i get 1950 per paycheck", "per_paycheck" ], [ "i get 1950", "biweekly" ], [ "i get 1950", "weekly" ] ].each do |message, cadence|
    test "#{message} read as #{cadence} is not given a frequency she never said" do
      say("Help me set up my household", read)
      body = say(message, income_read("1950", cadence, message))
      income = row(body, "primary_income")
      assert_equal "needs_monthly", income["status"]
      assert_nil income["total_cents"]
      refute_match(/two weeks|a week/, income["parts"].first["note"].to_s)
      assert_match(/how often/i, text(body))
      after = say("ok", read(setup: changes))
      assert_equal "needs_monthly", row(after, "primary_income")["status"]
    end
  end

  test "a frequency she states is kept, and bi-weekly is not weekly" do
    say("Help me set up my household", read)
    body = say("i get 1950 bi-weekly", income_read("1950", "biweekly", "i get 1950 bi-weekly"))
    assert_equal "$1,950 every two weeks, about $4,225 a month if that's right", row(body, "primary_income")["parts"].first["note"]
  end

  [ [ "car insurance 600 quarterly", "yearly", 20_000, /× 4/ ], [ "car insurance 600 twice a year", "yearly", 10_000, /× 2/ ], [ "car insurance 600 a year", "yearly", 5_000, /÷ 12/ ] ].each do |message, cadence, monthly, sum|
    test "#{message} works out to the right month" do
      say("Help me set up my household", read)
      body = say(message, read(setup: changes(fixed_expenses: money(parts: [ part("add", "car insurance", "600", cadence: cadence, source: message) ]))))
      assert_nil row(body, "fixed_expenses")["total_cents"]
      worked = say("help me work it out", read(setup: changes(help_topic: "fixed_expenses", work_out: true)))
      assert_match(sum, text(worked))
      amount = "$#{monthly / 100}"
      assert_match(/#{Regexp.escape(amount)} a month/, text(worked))
      assert_nil row(worked, "fixed_expenses")["total_cents"], "shown, not counted"
    end
  end

  def waiting_for_frequency
    say("Help me set up my household", read)
    say("hi", read(setup: changes))
    say("help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    say("1950", income_read("1950", "monthly", "1950"))
  end

  [ "semi monthly", "semi-monthly", "semimonthly", "twice a month", "2x a month" ].each do |answer|
    test "#{answer} after how often counts two paychecks" do
      waiting_for_frequency
      body = say(answer, read(setup: changes))
      assert_match(/That's \$3,900 a month \(1,950 × 2\)\. Use \$3,900\?/, text(body))
      assert_equal 390_000, row(say("yes", read(setup: changes)), "primary_income")["total_cents"]
    end
  end

  [ "bi-monthly", "bimonthly", "bi monthly" ].each do |answer|
    test "#{answer} after how often asks which she means" do
      waiting_for_frequency
      body = say(answer, read(setup: changes))
      assert_equal "needs_monthly", row(body, "primary_income")["status"]
      assert_nil row(body, "primary_income")["total_cents"]
      assert_match(/twice a month|every two months/i, text(body))
      answered = say("twice a month", read(setup: changes))
      assert_match(/Use \$3,900\?/, text(answered))
    end
  end

  test "semi monthly in one message counts two, even if the reader says monthly" do
    say("Help me set up my household", read)
    body = say("i get 1950 semi monthly", income_read("1950", "monthly", "i get 1950 semi monthly"))
    assert_match(/That's \$3,900 a month \(1,950 × 2\)\. Use \$3,900\?/, text(body))
    assert_equal 390_000, row(say("yes", read(setup: changes)), "primary_income")["total_cents"]
  end

  test "a typed row is not overwritten by an earlier proposal" do
    biweekly_income
    body = say("yeah help me work it out", read(setup: changes(help_topic: "primary_income", work_out: true)))
    income = row(body, "primary_income")["parts"].first
    edited = patch_card(card_of(body), field: "primary_income", action_name: "set", part_id: income["id"], value: "4300")
    assert_equal 430_000, edited["mia_action_draft"]["setup_card"]["rows"].find { |item| item["key"] == "primary_income" }["total_cents"]
    session.update!(active_topic: session.reload.active_topic.merge("setup_card_field" => "primary_income"))
    after = say("yes", read(setup: changes(confirm_monthly: true)))
    assert_equal 430_000, row(after, "primary_income")["total_cents"]
    refute_match(/4,225/, text(after))
  end

  test "frequency words count only as the answer to the frequency question" do
    waiting_for_frequency
    body = say("rent is 1100 every month", read(setup: changes(fixed_expenses: money(parts: [ part("add", "rent", "1100", source: "rent is 1100 every month") ]))))
    assert_equal "needs_monthly", row(body, "primary_income")["status"]
    assert_nil row(body, "primary_income")["total_cents"]
    assert_equal 110_000, row(body, "fixed_expenses")["total_cents"]
  end

  test "the closing line needs a real thank-you or a real resolution" do
    say("havent eaten today so the kids could", read(care: "hardship"))
    body = say("well manage somehow", read(care_status: "resolved"))
    assert care_topic
    refute_match(/glad|settled/i, text(body))

    fresh_user
    say("havent eaten today so the kids could", read(care: "hardship"))
    body = say("thanks we're ok", read(care_status: "resolved"))
    assert_not care_topic
    assert_match(/You're welcome/, text(body))
    refute_match(/settled|support/, text(body))

    fresh_user
    say("havent eaten today so the kids could", read(care: "hardship"))
    body = say("thanks but we still dont have food", read(care_status: "resolved"))
    assert care_topic
    refute_match(/You're welcome/, text(body))
  end

  test "the pause answer says only what is true" do
    answer = SavingsChallenge::ParticipantHelp::ANSWER
    assert_match(/can't pause the challenge yourself/, answer)
    assert_match(/program team would be the place to ask/, answer)
    refute_match(/coach|Only your/i, answer)
  end

  [ "should i finance a new iphone, 45 dollars a month", "should i finance a new iphone, 45 bucks a month" ].each do |message|
    test "#{message} is not a price" do
      reading = HouseholdFinance::ParticipantMessageReader.call(message: message,
        transport: ->(_) { legacy(question: true, purchase_question: { amount: "45", item: "iphone" }).to_json })
      assert_equal "", reading.purchase_question["amount"]
      assert HouseholdFinance::MiaCoachAnswerer.monthly_payment_question?(message)
    end
  end

  [ "I get paid $4,500 a month. Can I afford a stroller?", "my check is 4500 a month, can i get a stroller", "my paycheck is 4500 monthly, can i get a stroller", "should i get a gym membership, 40 a month", "thinking of a netflix subscription 15 a month" ].each do |message|
    test "#{message} is not a financed payment" do
      assert_not HouseholdFinance::MiaCoachAnswerer.monthly_payment_question?(message)
    end
  end

  test "a monthly subscription keeps its amount" do
    message = "should i get a gym membership, 40 a month"
    reading = HouseholdFinance::ParticipantMessageReader.call(message: message, transport: ->(_) { legacy(question: true, purchase_question: { amount: "40", item: "gym membership" }).to_json })
    assert_equal "40", reading.purchase_question["amount"]
  end
end
