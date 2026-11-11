require_relative "api_v1_pilot_leftovers_test"

# Permanent regressions from independent recheck-2's upload and unread-care probes.
class ApiV1CrisisPathSafetyTest < ApiV1PilotLeftoversTest
  def self.runnable_methods = public_instance_methods(false).map(&:to_s).grep(/\Atest_/)

  GUN = "I want to kill myself. I have a gun in my room.".freeze
  FOLLOWUPS = [ "I can't pay my rent", "I lost my job", "My truck broke down and I can't get to work", "my mom just died", "I want to join the challenge", "Change my saved purchase to $25" ].freeze

  def raw(message, **extra)
    post "/api/v1/mia/messages", params: { message: message }.merge(extra), headers: auth, as: :json
    assert_response :created
    response.parsed_body
  end

  # Model-enabled writer + unavailable reader exercise timeout override offline.
  def with_reader_timeout(available: false)
    reader = HouseholdFinance::ParticipantMessageReader
    original_reader = reader.method(:call)
    guard = Mia::ReplyGuard.method(:call)
    narrator = HouseholdFinance::MiaNarrator.instance_method(:openrouter_response)
    ENV["OPENROUTER_API_KEY"] = "synthetic-key"
    data = legacy
    reader.define_singleton_method(:call) do |**options|
      original_reader.call(**options.merge(transport: ->(_) { available ? JSON.generate(data) : raise(Net::ReadTimeout) }))
    end
    Mia::ReplyGuard.define_singleton_method(:call) { |**_| Mia::ReplyGuard::Result.new([ "sensitive_moment" ], care: "hardship") }
    HouseholdFinance::MiaNarrator.define_method(:openrouter_response) { answer_packet[:fallback_response] }
    yield
  ensure
    reader.define_singleton_method(:call, original_reader)
    Mia::ReplyGuard.define_singleton_method(:call, guard)
    HouseholdFinance::MiaNarrator.define_method(:openrouter_response, narrator)
    ENV["OPENROUTER_API_KEY"] = ""
  end

  def assert_crisis(body)
    assert_includes text(body), "988"
    assert_includes text(body), "Put distance between you and the gun"
    assert_equal true, body.dig("assistant_message", "safety_reply")
    assert_equal true, body.dig("assistant_message", "care_hold")
    assert_nil body["challenge_chat_card"]
    assert_nil body["mia_action_draft"]
    assert_equal "crisis", session.reload.active_topic["care_kind"]
  end

  %i[household challenge].each do |mode|
    %i[off on timeout].each do |model|
      %i[crisis grief].each do |care|
        test "#{mode} #{model} upload preserves active #{care}, import and reload hold" do
          enroll_in_challenge if mode == :challenge
          say(care == :crisis ? GUN : "my mom just died", legacy(care: care.to_s))
          original_topic = session.reload.active_topic
          import = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user,
            document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf",
            byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: SecureRandom.hex(32))
          before = import.attributes
          run = -> { raw("here is my statement", document_import_ids: [ import.id ]) }
          body = model == :off ? run.call : with_reader_timeout(available: model == :on) { run.call }
          assert_equal before, import.reload.attributes
          assert_equal original_topic.slice("care_kind", "started_at", "expires_at"), session.reload.active_topic.slice("care_kind", "started_at", "expires_at")
          assert_equal [ import.id ], ChatMessage.find(body.dig("user_message", "id")).attachments.map { |row| row["document_import_id"] }
          assert_crisis(body) if care == :crisis
          refute_match(/statement review|Start with one purchase/, text(body))
          get "/api/v1/mia/messages", headers: auth
          assert_response :success
          assert_equal true, response.parsed_body["messages"].last["care_hold"]
          assert_crisis(raw("I haven't moved it yet.")) if care == :crisis
        end
      end
      FOLLOWUPS.each do |followup|
        test "#{mode} #{model} keeps crisis guidance after #{followup}" do
          enroll_in_challenge if mode == :challenge
          say(GUN, legacy(care: "crisis"))
          body = model == :off ? raw(followup) : with_reader_timeout(available: model == :on) { raw(followup) }
          assert_crisis(body)
        end
      end
    end
    test "#{mode} model-off recovery closes warmly without onboarding" do
      enroll_in_challenge if mode == :challenge
      say(GUN, legacy(care: "crisis"))
      body = raw("I'm safe now, thanks")
      assert_equal "I'm glad you're safe. 988 is there any time, day or night.", text(body)
      assert_empty session.reload.active_topic
      assert_equal true, body.dig("assistant_message", "care_hold")
      assert_equal "crisis", session.open_topics.last["care_kind"]
    end
  end
  test "non-care writers including stale instances cannot replace care until state machine release" do
    say(GUN, legacy(care: "crisis"))
    stale = ChatSession.find(session.id)
    original = session.reload.active_topic
    [ {}, { "type" => "document_evidence" }, { "type" => "setup" }, { "type" => "challenge_goal" } ].each do |topic|
      stale.update!(active_topic: topic)
      assert_equal original, session.reload.active_topic
    end
    HouseholdFinance::ParticipantCareState.new(session).transition("I'm safe now, thanks",
      HouseholdFinance::ParticipantMessageReader.call(message: "I'm safe now, thanks", api_key: ""), history: [])
    assert_empty session.reload.active_topic
    stale.update!(active_topic: { "type" => "setup" })
    assert_equal "setup", session.reload.active_topic["type"]
  end
end

class ApiV1CrisisPathSafetyTest
  [ "Please tell my coach I want to quit the challenge. I'm not happy with it.",
    "I want to quit the challenge, I don't have the money anymore", "I don't want to quit but I want to pause the challenge" ].each do |message|
    test "unrelated negation preserves explicit coach request: #{message}" do
      enroll_in_challenge
      body = say(message, legacy)
      assert_equal SavingsChallenge::ParticipantHelp::TOLD, text(body)
      assert_equal 1, SetupSupportRequest.where(household: @household, reason: "leave_challenge").count
    end
  end
  test "procedural quit question and reminder enable request explain without notifying" do
    enroll_in_challenge
    assert_no_difference "SetupSupportRequest.count" do
      assert_equal SavingsChallenge::ParticipantHelp::EXPLANATION, text(raw("How do I quit?"))
      assert_match(/turn on the reminders you want/, text(raw("Can you turn on reminders for me?")))
    end
  end
end
