require "test_helper"
require_relative "../support/savings_challenge_test_support"

# Round 5, P1: the leftovers a guided pilot found, so a participant can use the app alone.
class ApiV1PilotLeftoversTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport

  EMPTY_MONEY = { none: false, total_amount: "", total_cadence: "", total_count: "", total_source: "", parts: [] }.freeze
  EMPTY_DEBT = { none: false, total_amount: "", total_source: "", parts: [] }.freeze

  setup do
    @user = User.create!(clerk_id: "p1_#{SecureRandom.hex(8)}", email: "p1-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
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

  def money(**values) = EMPTY_MONEY.merge(values)
  def debts(**values) = EMPTY_DEBT.merge(values)
  def debt(op, name, minimum, balance = "", source:) = { op: op, name: name, minimum: minimum, balance: balance, source: source }

  def auth
    { "Authorization" => "Bearer test_token_#{@user.id}" }.tap { |value| value["X-Cohort-Id"] = @savings_cohort.id.to_s if @savings_cohort }
  end

  def say(message, data, status: :created)
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    klass.define_singleton_method(:call) do |**options|
      new(**options.merge(transport: ->(_payload) { JSON.generate(data) })).call
    end
    post "/api/v1/mia/messages", params: { message: message }, headers: auth, as: :json
    assert_response status
    response.parsed_body
  ensure
    klass.define_singleton_method(:call, original)
  end

  def text(body) = body.dig("assistant_message", "content")
  def card_of(body) = body.dig("budget", "annual_plan", "pending_mia_action_drafts").to_a.find { |draft| draft["setup_card"] }
  def session = @household.chat_sessions.order(:id).last

  def apply(draft)
    post "/api/v1/mia_action_drafts/#{draft.fetch('id')}/apply", params: {}, headers: auth.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    response.parsed_body
  end

  def enroll_in_challenge
    setup_savings_context
    with_savings_runtime { savings_enroll }
    @user, @household = @savings_user, @savings_household
  end

  def setup_everything_but_debts
    say("Help me set up my household", read)
    say("taitano. get ahead. 5200 income. bills about 1950. everyday 600", read(setup: changes(household_name: "taitano", primary_goal: "get ahead",
      primary_income: money(total_amount: "5200", total_cadence: "monthly", total_source: "5200 income"),
      fixed_expenses: money(total_amount: "1950", total_cadence: "monthly", total_source: "bills about 1950"),
      flexible_spend: money(total_amount: "600", total_cadence: "monthly", total_source: "everyday 600"))))
  end

  # -- 1. The daily check-in prompt waits after personal support --------------------------------

  def care_session = @household.chat_sessions.order(:id).last

  test "the check-in prompt is held under a care reply, for the rest of that day, and then released" do
    say("Help me set up my household", read)
    body = say("sorry my husband just lost his job yesterday n rent is due friday its 1100, i dont know what were gonna do", read(care: "hardship"))
    assert_equal true, body.dig("assistant_message", "care_hold"), "the reply that cares carries the hold"

    get "/api/v1/mia/messages", headers: auth
    assert_equal true, response.parsed_body["messages"].last["care_hold"], "a reload keeps the hold"

    # Care closes when she moves on, yet the rest of the day still belongs to the hard news.
    care_session.update!(open_topics: [ care_session.active_topic.merge("last_care_at" => Time.current.iso8601) ], active_topic: {})
    get "/api/v1/mia/messages", headers: auth
    assert_equal true, response.parsed_body["messages"].last["care_hold"], "released care still holds for the day"

    travel_to Time.zone.now.tomorrow.change(hour: 9) do
      get "/api/v1/mia/messages", headers: auth
      assert_nil response.parsed_body["messages"].last["care_hold"], "the next morning the prompt is free"
    end
  end

  test "an ordinary reply carries no hold" do
    body = say("Help me set up my household", read)
    assert_nil body.dig("assistant_message", "care_hold")
    get "/api/v1/mia/messages", headers: auth
    assert_nil response.parsed_body["messages"].last["care_hold"]
  end

  test "the hold is read from care state without changing the conversation" do
    say("Help me set up my household", read)
    state = -> { HouseholdFinance::ParticipantCareState.new(care_session) }
    assert_not state.call.checkin_hold?
    care_session.update!(active_topic: HouseholdFinance::ParticipantCare.topic(:grief))
    assert state.call.checkin_hold?
    # A topic that ran out is not active, and a page load does not rewrite it.
    care_session.update!(active_topic: care_session.active_topic.merge("expires_at" => 1.hour.ago.iso8601, "last_care_at" => 3.days.ago.iso8601))
    before = care_session.updated_at
    assert_not state.call.checkin_hold?
    assert_equal before, care_session.updated_at
    # Older archived care from another day does not hold.
    care_session.update!(active_topic: {}, open_topics: [ { "type" => "care", "care_kind" => "grief", "started_at" => 2.days.ago.iso8601, "last_care_at" => 2.days.ago.iso8601 } ])
    assert_not state.call.checkin_hold?
    care_session.update!(open_topics: [ { "type" => "care", "care_kind" => "grief", "started_at" => 2.days.ago.iso8601, "last_care_at" => Time.current.iso8601 } ])
    assert state.call.checkin_hold?
  end

  # -- 2 and 3. A saving beside a question about leaving: both answered, the coach told ----------

  test "leaving the challenge is explained, and the coach finds the request in the support inbox" do
    enroll_in_challenge
    body = say("how do i quit the challenge", legacy(question: true))
    assert_equal SavingsChallenge::ParticipantHelp::TOLD, text(body)
    request = SetupSupportRequest.find_by!(household: @household, reason: "leave_challenge")
    assert_equal [ "requested", @savings_cohort.id, @user.id ], [ request.status, request.cohort_id, request.requested_by_user_id ]
    assert_equal "I asked to pause or leave the challenge", SetupHelp::Serializer.request(request)[:reason_label]
    assert HouseholdAuditEvent.exists?(event_type: "setup_support.requested", auditable_id: request.id)
  end

  test "asking twice does not double the request, and an open setup request is reworded so the coach sees this one" do
    enroll_in_challenge
    cohort_membership = @savings_membership
    SetupHelp::Participant.new(@household, user: @user, cohort_membership: cohort_membership).create_request(reason: "wrong_setup", share_metadata: true, idempotency_key: "first-#{SecureRandom.hex(4)}")
    say("how do i pause the challenge", legacy(question: true))
    say("seriously how do i quit this challenge", legacy(question: true))
    requests = SetupSupportRequest.where(household: @household, requested_by_user: @user)
    assert_equal 1, requests.count
    assert_equal "leave_challenge", requests.first.reason
    changed = HouseholdAuditEvent.find_by!(event_type: "setup_support.reason_changed", auditable_id: requests.first.id)
    assert_equal "wrong_setup", changed.metadata["previous_reason"]
  end

  test "Mia never claims the coach was told when the note could not be sent" do
    enroll_in_challenge
    participant = SetupHelp::Participant
    original = participant.instance_method(:request_leave)
    participant.define_method(:request_leave) { |**| raise SetupHelp::Denied, "not allowed" }
    begin
      body = say("how do i quit the challenge", legacy(question: true))
    ensure
      participant.define_method(:request_leave, original)
    end
    assert_equal SavingsChallenge::ParticipantHelp::NOT_TOLD, text(body)
    refute_match(/I've let your coach know/, text(body))
    assert_equal 0, SetupSupportRequest.where(household: @household, reason: "leave_challenge").count
  end

  test "a staff preview cannot raise a leave request, and Mia says to ask directly" do
    enroll_in_challenge
    preview = @savings_membership
    preview.define_singleton_method(:preview?) { true }
    answer = SavingsChallenge::ParticipantHelp.exit_answer("how do i quit the challenge", household: @household, user: @user, membership: preview)
    assert_equal SavingsChallenge::ParticipantHelp::NOT_TOLD, answer
    assert_equal 0, SetupSupportRequest.where(household: @household).count
  end

  test "a saving with a question about quitting makes the card and answers the question" do
    enroll_in_challenge
    body = say("I put $50 aside today, how do i quit the challenge?", legacy(question: true, facts: [ { kind: "set_aside", amount: "50", merchant: "", item: "", day: "", source_text: "I put $50 aside today" } ]))
    assert_equal 5000, body.dig("savings_intake", "amount_cents")
    assert body["challenge_chat_card"].present?
    assert_includes text(body), SavingsChallenge::ParticipantHelp::TOLD
    assert_includes text(body), "$50"
    refute_match(/\$50\.00/, text(body))
  end

  test "the ways people ask to leave are recognised, and spending questions are not" do
    [ "how do i quit the challenge", "i'm thinking about stopping the challenge", "can i pause this challenge", "i want to leave the program", "how do I cancel my challenge",
      "I'm withdrawing from the savings challenge", "how do i get out of the challenge", "i need to step away from the challenge" ].each do |message|
      assert SavingsChallenge::ParticipantHelp.exit?(message), message
    end
    [ "how do i stop overspending during the challenge", "should i pause my gym membership", "how am I doing in the challenge", "what is the challenge" ].each do |message|
      assert_not SavingsChallenge::ParticipantHelp.exit?(message), message
    end
  end

  test "a purchase beside a question about stopping gets its card and the answer" do
    enroll_in_challenge
    body = say("I spent $12 at Shell and I'm thinking about stopping the challenge, how do I pause it?",
      legacy(question: true, facts: [ { kind: "purchase", amount: "12", merchant: "Shell", item: "", day: "", source_text: "I spent $12 at Shell" } ]))
    assert body["challenge_chat_card"].present?
    assert_includes text(body), SavingsChallenge::ParticipantHelp::TOLD
  end

  test "a hard moment is not answered with the leave explanation" do
    enroll_in_challenge
    body = say("my dad passed away friday and i dont think i can keep going with the challenge", legacy(care: "grief"))
    refute_includes text(body), SavingsChallenge::ParticipantHelp::TOLD
    assert_equal 0, SetupSupportRequest.where(household: @household, reason: "leave_challenge").count
  end

  # -- 4. Whole dollars read as "$50" ------------------------------------------------------------

  test "money in Mia's sentences drops .00 and keeps real cents" do
    assert_equal [ "$50", "$12.50", "$1,234.56", "$0", "-$50" ], [ 5000, 1250, 123_456, 0, -5000 ].map { |cents| HouseholdFinance::Money.plain(cents) }
    enroll_in_challenge
    answer = SavingsChallenge::CoachAnswerer.new(household: @household, user: @user, enrollment: @savings_enrollment, message: "ok")
    assert_equal [ "$50", "$12.50" ], [ answer.send(:money, 5000), answer.send(:money, 1250) ]
  end

  test "a correction in chat names whole dollars without cents" do
    enroll_in_challenge
    savings_plan
    savings_approve(savings_draft(2000))
    body = say("actually that was 30 not 20", legacy(savings_correction: { old_amount: "20", new_amount: "30", day: "" }))
    assert_match(/Replace \$20 with \$30\?/, text(body))
    assert_no_match(/\.00/, text(body))
  end

  # -- 5. Care replies do not bring back an old purchase -----------------------------------------

  test "a care reply is written from the conversation where she disclosed it, not from older purchase chats" do
    say("Help me set up my household", read)
    say("can i afford a $300 stroller", legacy(question: true))
    @household.chat_sessions.flat_map { |chat| chat.chat_messages.to_a }.each { |message| message.update_columns(created_at: 4.days.ago) }
    seen = []
    narrator = HouseholdFinance::MiaNarrator
    original = narrator.instance_method(:initialize)
    narrator.define_method(:initialize) { |**options| seen << options[:history]; original.bind(self).call(**options) }
    begin
      say("my dad just passed away", read(care: "grief"))
      say("i just feel numb", read(care_status: "ongoing"))
    ensure
      narrator.define_method(:initialize, original)
    end
    assert seen.any?, "the care reply was written"
    seen.flatten.each { |turn| refute_match(/stroller/i, turn[:content].to_s) }
    assert_equal 0, seen.first.size, "the first care reply has no earlier turns"
    assert_includes seen.last.map { |turn| turn[:content] }.join(" "), "passed away", "the next one continues the disclosure"
  end

  test "the care writer is told to name only what she named in this conversation" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "i feel numb", api_key: "k", answer_packet: { kind: "coaching", care_context: { "care_kind" => "grief" }, fallback_response: "x" })
    assert_match(/only if she named it in this conversation; never one from an earlier chat/, narrator.send(:narrator_contract))
  end

  # -- 6. Purchase answers help her decide ------------------------------------------------------

  test "purchase wording leaves the decision with her" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "can i get a tv", api_key: "k", answer_packet: { kind: "purchase_scenario", purchase_prefix: "The plan has room.", fallback_response: "x" })
    contract = narrator.send(:purchase_contract)
    refute_match(/Start with a cautious stance|wait or hold off/, contract)
    assert_match(/Help her decide; do not decide for her/, contract)
    assert_match(/Never tell her to wait, hold off, skip, drop, buy or get it/, contract)
    fixed = narrator.send(:fallback_response)
    refute_match(/hold off/i, fixed)

    unfunded = HouseholdFinance::MiaNarrator.new(user_message: "i dont have the money but can i put a $650 tv on my card", api_key: "k",
      answer_packet: { kind: "purchase_scenario", purchase_prefix: "A $650 tv would leave $700.", fallback_response: "x" })
    refute_match(/hold off/i, unfunded.send(:fallback_response))
    assert_match(/The open question is what would cover it/, unfunded.send(:fallback_response))
  end

  test "the challenge purchase answer asks how she would cover it instead of telling her to hold off" do
    enroll_in_challenge
    answer = SavingsChallenge::CoachAnswerer.new(household: @household, user: @user, enrollment: @savings_enrollment, message: "i dont have the money but can i put a $650 tv on my card?").send(:purchase_answer)
    refute_match(/hold off/i, answer)
    assert_match(/how you would cover it/, answer)
    assert_match(/\?\z/, answer)
  end

  # -- 7. A win is a CFO move, never effort ------------------------------------------------------

  test "a win is called a CFO move and never praised as effort" do
    [ HouseholdFinance::MiaCoachAnswerer::WIN_ANSWER, HouseholdFinance::MiaCoachAnswerer::LIMIT_WIN_ANSWER ].each do |answer|
      assert_match(/CFO move/, answer)
      refute_match(/effort|kept at it|keep going|great job|proud/i, answer)
      assert_match(/\?\z/, answer)
    end
    contract = HouseholdFinance::MiaNarrator.new(user_message: "i paid 300 extra on my visa", api_key: "k", answer_packet: { kind: "coaching", fallback_response: "x" }).send(:narrator_contract)
    assert_match(/call it a CFO move.*never praise effort, discipline, grit, sacrifice or keeping at it/, contract)
  end

  test "a budget win and a plain win read as hers" do
    answerer = ->(message) { HouseholdFinance::MiaCoachAnswerer.new(@household, message).send(:win_answer) }
    assert_equal HouseholdFinance::MiaCoachAnswerer::LIMIT_WIN_ANSWER, answerer.call("I stayed under my grocery budget all week!")
    assert_equal HouseholdFinance::MiaCoachAnswerer::LIMIT_WIN_ANSWER, answerer.call("I stuck to my food budget this week.")
    assert_equal HouseholdFinance::MiaCoachAnswerer::WIN_ANSWER, answerer.call("I paid an extra $300 on my credit card this month")
  end

  # -- 8. Setup wording --------------------------------------------------------------------------

  test "resuming setup after hardship reads as a sentence" do
    say("Help me set up my household", read)
    say("sorry my husband just lost his job yesterday n rent is due friday its 1100, i dont know what were gonna do", read(care: "hardship"))
    body = say("ok lets keep goin w this, its only my check now, 2400 a month", read(care_status: "ongoing", setup: changes(primary_income: money(total_amount: "2400", total_cadence: "monthly", total_source: "its only my check now, 2400 a month"))))
    assert_match(/Your income is \$2,400 a month\./, text(body))
    refute_match(/\bIncome: /, text(body))
  end

  test "named debts read as one sentence, then say which one needs a minimum" do
    setup_everything_but_debts
    body = say("the car is 240 and a personal loan, dont know the min", read(setup: changes(debt_payment: debts(parts: [ debt("add", "car", "240", source: "the car is 240"), debt("add", "personal loan", "", source: "a personal loan, dont know the min") ]))))
    assert_includes text(body), "Added car $240 and personal loan. The personal loan needs a minimum."
    refute_match(/Added personal loan\./, text(body))
  end

  test "one debt with no minimum is added in one line" do
    setup_everything_but_debts
    body = say("a personal loan, dont know the min", read(setup: changes(debt_payment: debts(parts: [ debt("add", "personal loan", "", source: "a personal loan, dont know the min") ]))))
    assert_includes text(body), "Added personal loan. It needs a minimum."
  end

  test "after Apply the guide asks about the minimum she left out, not about debts all over again" do
    setup_everything_but_debts
    body = say("the car is 240 and a personal loan, dont know the min", read(setup: changes(debt_payment: debts(parts: [ debt("add", "car", "240", source: "the car is 240"), debt("add", "personal loan", "", source: "a personal loan, dont know the min") ]))))
    apply(card_of(body))
    message = HouseholdFinance::MiaSetupGuide.new(@household.reload).after_apply_message
    assert_equal "What's the monthly minimum on your personal loan?", message
    refute_match(/What do you pay on debts/, message)
  end

  test "the field subjects and verbs agree" do
    reply = HouseholdFinance::MiaSetupCardReply
    assert_equal [ "Your income", "is" ], [ reply.subject("primary_income"), reply.verb("primary_income") ]
    assert_equal [ "Your fixed essentials", "are" ], [ reply.subject("fixed_expenses"), reply.verb("fixed_expenses") ]
    assert_equal [ "Your everyday spending", "is" ], [ reply.subject("flexible_spend"), reply.verb("flexible_spend") ]
    assert_equal [ "What you owe", "is" ], [ reply.subject("credit_card_debt"), reply.verb("credit_card_debt") ]
    assert_equal [ "Your emergency fund", "is" ], [ reply.subject("emergency_fund"), reply.verb("emergency_fund") ]
  end

  # -- 11. The as-needed phrase gets a cooldown --------------------------------------------------

  test "an as-needed phrase stays out of the last three replies" do
    policy = Mia::LanguagePolicy.allocate
    phrase = "Chelu, pump the brakes."
    replies = ->(*recent) { policy.define_singleton_method(:assistant_history) { recent } }
    replies.call("Sure.", "Sure.", "Chelu, pump the brakes. Wait for it.")
    assert policy.send(:custom_phrase_recently_used?, phrase, "as_needed")
    replies.call("Chelu, pump the brakes. Wait for it.", "Sure.", "Sure.", "Sure.")
    assert_not policy.send(:custom_phrase_recently_used?, phrase, "as_needed")
  end
end
