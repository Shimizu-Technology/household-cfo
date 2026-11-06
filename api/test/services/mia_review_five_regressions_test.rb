require "test_helper"
require_relative "../support/persona_test_helper"

class MiaReviewFiveRegressionsTest < ActiveSupport::TestCase
  include PersonaTestHelper

  teardown { HouseholdFinance::ParticipantMessageReader::Current.reset }

  def with_method(object, name, replacement)
    old = object.method(name)
    object.define_singleton_method(name, replacement)
    yield
  ensure
    object.define_singleton_method(name, old) if old
  end

  def read_care(message, care)
    reading = HouseholdFinance::ParticipantMessageReader.new(message: message, transport: ->(_) { { care: care, facts: [], question: true,
      setup_answer: { field: "none", value: "" }, correction: false, spending_preferences: [] }.to_json }).call
    HouseholdFinance::ParticipantMessageReader::Current.message = message
    HouseholdFinance::ParticipantMessageReader::Current.reading = reading
    reading
  end

  test "R5 current care precedes model shape guard outage and figures in both delivery paths" do
    { "We buried my husband on Tuesday. Could I buy a $200 headstone deposit?" => "grief",
      "The layoffs happened and I have no income now. Could I get shoes?" => "hardship",
      "I feel so ashamed of who I am. Can I get shoes?" => "shame" }.each do |message, care|
      read_care(message, care)
      expected = HouseholdFinance::ParticipantCare.answer(message)
      narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "fake",
        answer_packet: { kind: "purchase_scenario", fallback_response: "The $200 price would leave $700 in the plan, not cash." })
      narrator.define_singleton_method(:openrouter_response) { "bad " * 1000 }
      responder = Demo::MiaResponder.new(api_key: "fake")
      responder.define_singleton_method(:openrouter_response) { |*| raise Net::ReadTimeout }
      assert_equal expected, narrator.call
      assert_equal expected, responder.call(message, context: "{}")
    end
  end

  test "R5 crisis reading is typed and uses crisis boundary with no setup coaching" do
    message = "I don't know how much longer I can keep doing this"
    reading = read_care(message, "crisis")
    assert_equal "crisis", reading.care
    assert_equal Mia::CrisisBoundary.response, HouseholdFinance::ParticipantCare.answer(message)
    narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "", answer_packet: { kind: "coaching", fallback_response: "Which month and year?" })
    assert_equal Mia::CrisisBoundary.response, narrator.call
  end

  test "R5 current none care overrides incidental grief words and third party hardship" do
    [ "It's been a hard week but can I get $30 socks?", "My cousin lost her job but I'm doing fine.",
      "i dont know how much longer i can keep doing this job", "im done with this budget", "this is killing me lol", "dead tired",
      "My dad passed away years ago; I'm doing fine and this is unrelated. Can I get socks?" ].each do |message|
      read_care(message, "none")
      refute HouseholdFinance::ParticipantCare.required?(message), message
      responder = Demo::MiaResponder.new(api_key: "")
      reply = responder.call(message, context: "{}")
      refute_equal Mia::CrisisBoundary.response, reply, message
      refute_match(/sorry for your loss|does not make you a failure/, reply, message)
    end
  end

  test "R5 a none reading prevents model-written crisis guidance for ordinary idioms" do
    text = "Feeling dead tired is a real signal, and it makes sense that you are worn down. I'm Mia, a digital assistant guided by Mrs. Mel's approach, and nothing about money needs to be decided tonight. If this tiredness feels heavy or hopeless, please call or text 988, or get next to someone you trust. If it is a long day, what is one thing you can set down tonight so you can rest?"
    [ "dead tired", "this is killing me lol", "im done with this budget", "i dont know how much longer i can keep doing this job" ].each do |message|
      read_care(message, "none")
      narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "fake", answer_packet: { kind: "coaching", fallback_response: "Check the plan first. Which bill comes next?" })
      responder = Demo::MiaResponder.new(api_key: "fake")
      assert_equal :unexpected_crisis_guidance, narrator.send(:narration_rejection_reason, text, guard_covered: true)
      assert_equal "unexpected_crisis_guidance", responder.send(:generic_claim_rejection, text, context: "{}", user_message: message, guard_covered: true).to_s
      responder.define_singleton_method(:openrouter_response) { |*, **_| text }
      with_method(Mia::ReplyGuard, :call, ->(**_) { Mia::ReplyGuard::Result.new([], care: "none") }) do
        refute Mia::CrisisBoundary.safety_reply?(responder.call(message, context: "{}")), message
        assert_equal :unexpected_crisis_guidance, responder.rejection_reason
      end
    end
  end

  test "R5 crisis guidance stays available for crisis readings direct hotline questions and the crisis floor" do
    text = Mia::CrisisBoundary.response
    message = "What does 988 do?"
    read_care(message, "none")
    refute HouseholdFinance::ParticipantCare.unexpected_crisis_guidance?(message, text)
    message = "I don't know how much longer I can keep doing this"
    read_care(message, "crisis")
    refute HouseholdFinance::ParticipantCare.unexpected_crisis_guidance?(message, text)
    message = "I want to kill myself"
    read_care(message, "none")
    refute HouseholdFinance::ParticipantCare.unexpected_crisis_guidance?(message, text)
    HouseholdFinance::ParticipantMessageReader::Current.reset
    assert HouseholdFinance::ParticipantCare.unexpected_crisis_guidance?("dead tired", text, care: "none")
    refute HouseholdFinance::ParticipantCare.unexpected_crisis_guidance?("dead tired", text)
  end

  test "R5 CR stated and denied purchases distinguish visits from buying" do
    [ "I keep going to Ross and buying clothes", "I keep going to Ross but I didn't buy shoes and bought clothes" ].each do |message|
      coach = HouseholdFinance::MiaCoachAnswerer.allocate
      coach.instance_variable_set(:@message, message)
      refute_includes coach.send(:repeated_pattern_answer), "A visit does not tell me"
    end
    [ "I keep going to Ross", "I keep going to Ross without buying anything", "I keep going to Ross but I don't buy anything", "I keep going to Ross and bought nothing" ].each do |message|
      coach = HouseholdFinance::MiaCoachAnswerer.allocate
      coach.instance_variable_set(:@message, message)
      assert_includes coach.send(:repeated_pattern_answer), "A visit does not tell me", message
    end
  end

  test "R5 CR challenge income purchase fallback cannot imply an approved household comparison" do
    prefix = "There is no household plan in this challenge to compare a purchase against, and I cannot verify the cash or card payments you would need."
    narrator = SavingsChallenge::Narrator.new(user_message: "My income is now $5,600 monthly. Could I buy a $740 laptop?", api_key: "",
      answer_packet: { kind: "purchase_scenario", purchase_prefix: prefix, fallback_response: prefix })
    reply = narrator.call
    assert_includes reply, "no household plan"
    refute_includes reply, "this comparison uses your approved plan"
  end

  test "R5 CR narrator guard facts prioritize safety over large conversation memory" do
    packet = { kind: "coaching", write_state: "no_write", fallback_response: "Your plan leaves $1,450, not bank cash.", annual_plan_summary: { plan_left_cents: 145000 },
      personalization_memory: { memories: [ "long " * 15000 ] }, conversation_state: { summary: "old " * 15000 } }
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "What is left in my plan?", answer_packet: packet, api_key: "fake")
    seen = nil
    with_method(Mia::ReplyGuard, :call, ->(**options) { seen = options[:facts]; Mia::ReplyGuard::Result.new([]) }) do
      narrator.send(:guard_reply, "Which bill comes next?")
    end
    assert_operator seen.to_json.bytesize, :<=, 12000
    assert_equal 145000, seen.dig(:annual_plan_summary, :plan_left_cents)
    assert_equal "no_write", seen[:write_state]
    assert_equal packet[:fallback_response], seen[:fallback_response]
    refute seen.key?(:personalization_memory)
  end

  test "R5 CR guard fact budget reserves the wire envelope and fails closed on oversized required truth" do
    flags = Mia::ReplyGuard::FLAGS.index_with { false }.merge("care" => "none", "history_sensitive" => false)
    facts = { fallback_response: "Your plan leaves $1,450, not bank cash.", annual_plan_summary: { plan_left_cents: 145000 }, personalization_memory: "x" * 11000 }
    history = 8.times.map { { role: "user", content: "字" * 600 } }
    guard = Mia::ReplyGuard.new(user_message: "😀" * 7000, history: history, facts: facts, reply: "r" * 3000, api_key: "fake")
    guard.define_singleton_method(:classify) { flags.to_json }
    with_method(HouseholdFinance::MiaProviderAdmission, :with_slot, ->(**_, &block) { block.call }) do
      assert guard.call.allowed?
    end
    data = guard.instance_variable_get(:@data)
    assert_operator data.to_json.bytesize, :<=, 48000
    assert_equal 145000, data.dig(:allowed_facts, :annual_plan_summary, :plan_left_cents)
    too_large = Mia::ReplyGuard.new(user_message: "What is left?", history: [], facts: { fallback_response: "x" * 13000 }, reply: "Check the plan.", api_key: "fake")
    too_large.define_singleton_method(:classify) { raise "required facts must not be sent" }
    assert_equal [ "input_limit" ], too_large.call.reasons
  end

  test "R5 CR current none never suppresses certain household food insecurity" do
    message = "We have no food this week. Can I buy a $300 TV?"
    read_care(message, "none")
    assert_equal :food, HouseholdFinance::ParticipantCare.kind(message)
    assert Mia::SensitiveMoment.matches?(message)
    narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "", answer_packet: { kind: "purchase_scenario", fallback_response: "The $300 TV would leave $1,150, not bank cash." })
    reply = narrator.call
    assert_match(/food|eat/, reply)
    refute_includes reply, "$300"
    [ "My cousin has no food this week but we are doing fine. Can I buy a $300 TV?", "We have no food expenses this week. Can I buy a $300 TV?" ].each do |other|
      read_care(other, "none")
      refute HouseholdFinance::ParticipantCare.required?(other), other
      refute Mia::SensitiveMoment.matches?(other), other
    end
  end

  test "R5 CR unavailable reader clarification uses guard detected grief without a second read" do
    message = "Since the farewell, the house feels empty."
    current = HouseholdFinance::ParticipantMessageReader::Current
    unavailable = HouseholdFinance::ParticipantMessageReader.new(message: message, api_key: "").call
    current.message, current.reading = message, unavailable
    controller = Api::V1::MiaMessagesController.new
    controller.define_singleton_method(:params) { ActionController::Parameters.new(message: message) }
    intent = HouseholdFinance::MiaIntentResolver::Result.new(intent: "coaching", confidence: 1.0, continuation: false,
      resolved_message: message, needs_clarification: true, clarification: "Which month?", topic: {}, action: { type: "none" }, read_only_plan: {}, source: "model")
    calls = 0
    with_method(HouseholdFinance::ParticipantMessageReader, :call, ->(**_) { raise "a second reader is forbidden" }) do
      with_method(Mia::ReplyGuard, :call, ->(**_) { calls += 1; Mia::ReplyGuard::Result.new([ "sensitive_moment" ], care: "grief") }) do
        reply = controller.send(:clarification_answer, intent)
        assert_equal HouseholdFinance::ParticipantCare.answer(message, care: "grief"), reply
        refute_includes reply, "Which month"
        assert_equal 1, calls
      end
    end
  end

  test "R5 guard current care is separate from historical sensitivity and preserves grief type" do
    message = "My dog died and the house is quiet. Can I get a chair?"
    flags = Mia::ReplyGuard::FLAGS.index_with { false }.merge("sensitive_moment" => true, "care" => "grief", "history_sensitive" => false)
    guard = Mia::ReplyGuard.new(user_message: message, history: [], facts: {}, reply: "Which month?", api_key: "fake")
    guard.define_singleton_method(:classify) { flags.to_json }
    result = guard.call
    assert result.sensitive?
    assert_equal "grief", result.care
    narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "fake", answer_packet: { kind: "coaching", fallback_response: "The plan has $700, not cash." })
    narrator.define_singleton_method(:openrouter_response) { "Hold off for now. Which account would cover it?" }
    with_method(Mia::ReplyGuard, :call, ->(**_) { result }) do
      assert_match(/sorry for your loss/, narrator.call)
    end
    flags.merge!("sensitive_moment" => false, "care" => "none", "history_sensitive" => true)
    result = guard.call
    assert result.allowed?, result.reasons.inspect
    refute result.sensitive?
    assert result.history_sensitive
  end

  test "R5 false positive guard care cannot overrule an available current none reading" do
    [ "It's been a hard week but can I get $30 socks?", "My cousin lost her job but I'm doing fine." ].each do |message|
      read_care(message, "none")
      narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "fake", answer_packet: { kind: "coaching", fallback_response: "Check the plan first. Which bill comes next?" })
      narrator.define_singleton_method(:openrouter_response) { "Hold off for now. Check the funding first. Which bill comes next?" }
      with_method(Mia::ReplyGuard, :call, ->(**_) { Mia::ReplyGuard::Result.new([ "sensitive_moment" ], care: "hardship") }) do
        with_method(HouseholdFinance::MiaProviderAdmission, :with_slot, ->(**_, &block) { block.call }) do
          assert_equal "Check the plan first. Which bill comes next?", narrator.call
          assert_equal "deterministic_fallback", narrator.response_source
        end
      end
    end
  end

  test "R5 history sensitivity removes only the coach phrase and preserves guarded fixed figures" do
    message = "Can I get a $40 pair of shoes?"
    read_care(message, "none")
    fixed = "This month’s plan has $1,450 left, so $40 shoes would leave $1,410 if it is extra spending, and that's a plan figure, not your bank balance."
    narrator = HouseholdFinance::MiaNarrator.new(user_message: message, api_key: "fake", history: [ { role: "user", content: "I lost my job yesterday." } ],
      answer_packet: { kind: "purchase_scenario", fallback_response: fixed })
    coaching = "Hold off on the shoes for now. Keep rent protected first. Could the shoes wait?"
    narrator.define_singleton_method(:openrouter_response) { coaching }
    with_method(Mia::ReplyGuard, :call, ->(**_) { Mia::ReplyGuard::Result.new([], care: "none", history_sensitive: true) }) do
      with_method(HouseholdFinance::MiaProviderAdmission, :with_slot, ->(**_, &block) { block.call }) do
        assert_equal "#{fixed} #{coaching}", narrator.call
        assert_equal "live_model", narrator.response_source
      end
    end
  end

  test "R5 hardship history shapes coaching without replacing the requested answer and recovery clears it" do
    persona = create_persona
    history = [ { role: "user", content: "I lost my job yesterday." } ]
    message = "Can I get a $40 pair of shoes?"
    policy = Mia::LanguagePolicy.new(user_message: message, history: history, persona: persona)
    assert policy.send(:sensitive_moment?)
    recovered = history + [ { role: "user", content: "I started a new job last month and things are steady now" } ]
    refute Mia::LanguagePolicy.new(user_message: message, history: recovered, persona: persona).send(:sensitive_moment?)
    unrelated_grief = [ { role: "user", content: "My sister died this weekend" } ] + recovered
    assert Mia::LanguagePolicy.new(user_message: message, history: unrelated_grief, persona: persona).send(:sensitive_moment?)
  end

  test "R5 guard failures preserve HTTP status without content and notify for both guards" do
    http = Object.new
    http.define_singleton_method(:request) do |*|
      Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable").tap { |r| r.instance_variable_set(:@read, true); r.body = '{"secret":"participant message"}' }
    end
    events = []
    with_method(ProviderOutageAlert, :guard_failure, ->(**data) { events << data }) do
      with_method(OpenRouterConnection, :start, ->(*_, **_, &block) { block.call(http) }) do
        with_method(HouseholdFinance::MiaProviderAdmission, :with_slot, ->(**_, &block) { block.call }) do
          guard = Mia::ReplyGuard.new(user_message: "private", history: [], facts: {}, reply: "Which account?", api_key: "fake")
          refute guard.call.allowed?
          proposal = Mia::PersonaSetup::ProposalGuard.call(user_message: "private", operation: { "evidence_quote" => "private" }, current_value: nil, api_key: "fake")
          refute proposal.allowed?
        end
      end
    end
    assert_equal [ "mia_reply_guard", "persona_setup_guard" ], events.map { |event| event[:service] }
    assert_equal [ 503, 503 ], events.map { |event| event[:status] }
    refute_includes events.to_json, "private"
    refute_includes events.to_json, "participant message"
  end

  test "R5 guard alerts rate limit and never send participant or provider content" do
    events = []
    sentry = Module.new do
      define_singleton_method(:initialized?) { true }
      define_singleton_method(:capture_message) { |*args, **options| events << [ args, options ] }
    end
    old_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    old_sentry = Object.const_get(:Sentry) if Object.const_defined?(:Sentry)
    Object.send(:remove_const, :Sentry) if old_sentry
    Object.const_set(:Sentry, sentry)
    2.times { ProviderOutageAlert.guard_failure(service: "mia_reply_guard", status: 503, error_class: "Net::ReadTimeout") }
    ProviderOutageAlert.guard_failure(service: "persona_setup_guard", status: 429, error_class: "Unavailable")
    assert_equal 2, events.length
    assert_equal [ 503, 429 ], events.map { |event| event.last.dig(:tags, :ai_status) }
    output = StringIO.new
    AiModels.log_configuration(logger: ActiveSupport::Logger.new(output), env: { "AI_REPLY_GUARD_MODEL" => "test/reply", "AI_PROPOSAL_GUARD_MODEL" => "test/proposal" })
    assert_includes output.string, "reply_guard=test/reply"
    assert_includes output.string, "proposal_guard=test/proposal"
  ensure
    Rails.cache = old_cache
    Object.send(:remove_const, :Sentry)
    Object.const_set(:Sentry, old_sentry) if old_sentry
  end

  test "R5 a slow connection consumes only the shared remaining deadline" do
    http_start = Net::HTTP.method(:start)
    Net::HTTP.define_singleton_method(:start) { |*, **_, &block| sleep 0.2; block.call(Object.new) }
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Mia::ReplyDeadline::Current.set(expires_at: start + 0.02) do
      assert_raises(Mia::ReplyDeadline::Exceeded) { OpenRouterConnection.start(URI("https://example.invalid"), read_timeout: 12, open_timeout: 3) { flunk "slow connection must be interrupted" } }
      assert_raises(Mia::ReplyDeadline::Exceeded) { Mia::ReplyDeadline.within { Mia::ReplyDeadline.check! } }
    end
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - start, :<, 0.15
  ensure
    Net::HTTP.define_singleton_method(:start, http_start)
  end

  test "R5 one deadline bounds the entire provider chain and returns fixed fallback" do
    narrator = HouseholdFinance::MiaNarrator.new(user_message: "Can I get shoes?", api_key: "fake", answer_packet: { kind: "coaching", fallback_response: "Check the plan first. Which bill comes next?" })
    narrator.define_singleton_method(:openrouter_response) { Mia::ReplyDeadline.check!; "Hold off for now. Which account would cover it?" }
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1
    Mia::ReplyDeadline::Current.set(expires_at: deadline) do
      assert_equal "Check the plan first. Which bill comes next?", narrator.call
      assert_raises(Mia::ReplyDeadline::Exceeded) { OpenRouterConnection.start(URI("https://example.invalid"), read_timeout: 12, open_timeout: 3) { flunk "must not open expired connection" } }
    end
  end
end
