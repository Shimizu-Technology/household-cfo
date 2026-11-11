require "test_helper"

class ParticipantCareStateTest < ActiveSupport::TestCase
  setup do
    @user, household = HouseholdFinance::MiaEvalHousehold.create!
    @session = household.chat_sessions.create!(user: @user, active_topic: HouseholdFinance::ParticipantCare.topic(:grief))
    @state = HouseholdFinance::ParticipantCareState.new(@session)
  end

  teardown { HouseholdFinance::ParticipantMessageReader::Current.reset }

  def reading(message, care: "none", status: "none", question: false)
    result = HouseholdFinance::ParticipantMessageReader.call(message: message, transport: ->(_) { { care: care, care_status: status, question: question }.to_json })
    current = HouseholdFinance::ParticipantMessageReader::Current
    current.message, current.reading, current.recent_care = message, result, "grief"
    result
  end

  %w[hardship food].each do |kind|
    test "crisis inside an older #{kind} episode renews care without changing its start" do
      now = Time.current.change(usec: 0)
      travel_to(now) { @session.update!(active_topic: HouseholdFinance::ParticipantCare.topic(kind)) }
      started = @session.active_topic.fetch("started_at")
      travel_to(now + 47.hours + 50.minutes) do
        topic = @state.record_crisis("I want to die tonight.")
        assert_equal started, topic["started_at"]
        assert_equal (Time.current + 48.hours).iso8601, topic["expires_at"]
      end
      travel_to(now + 48.hours + 10.minutes) { assert @state.checkin_hold? }
    end
  end

  test "sixty two messages bound storage while keeping first safety disclosures and recent turns" do
    @session.release_care_topic!
    first = "I want to kill myself. I have a gun in my room."
    @state.record_crisis(first)
    @state.record_crisis("I plan to act at 9 tonight.")
    60.times { |i| @state.transition("Still here #{i}. " * 150, reading("Still here", status: "ongoing"), history: []) }
    topic = @session.reload.active_topic
    assert_operator topic["disclosures"].size, :<=, HouseholdFinance::CareDisclosures::LIMIT
    assert_operator topic.to_json.bytesize, :<, 10_000
    assert_includes topic.to_json, first
    assert_includes topic.to_json, "9 tonight"
    assert_includes topic.to_json, "Still here 59"
  end

  test "only a safety reply belonging to an expired episode can release the check-in prompt" do
    started = 3.days.ago
    topic = HouseholdFinance::ParticipantCare.topic(:crisis).merge("started_at" => started.iso8601, "expires_at" => 1.day.ago.iso8601)
    @session.update!(active_topic: topic)
    assert_not @state.checkin_hold?(safety_reply_at: started + 1.minute)
    assert @state.checkin_hold?(safety_reply_at: Time.current), "a new wellbeing check has its own hold"
    @session.update!(active_topic: {}, open_topics: [ topic.merge("last_care_at" => (started + 1.hour).iso8601) ])
    assert_not @state.checkin_hold?(safety_reply_at: started + 1.minute)
    assert @state.checkin_hold?(safety_reply_at: Time.current)
    @session.update!(active_topic: HouseholdFinance::ParticipantCare.topic(:crisis), open_topics: [])
    assert @state.checkin_hold?(safety_reply_at: Time.current)
  end

  test "a practical challenge question releases care even if the reader calls it ongoing" do
    text = "can i stop the challenge for a bit"
    assert_nil @state.transition(text, reading(text, status: "ongoing", question: true), history: [])
    assert_empty @session.reload.active_topic
    assert @state.recently_released?
  end

  test "an open question still inside the hard moment stays in care" do
    text = "what do i even do now"
    assert_equal "grief", @state.transition(text, reading(text, status: "ongoing", question: true), history: []).fetch("care_kind")
  end

  test "a crisis release is never treated as recently released care" do
    @session.update!(open_topics: [ HouseholdFinance::ParticipantCare.topic(:crisis) ])
    @session.release_care_topic!
    refute @state.recently_released?
  end

  test "crisis latch survives another care label and a money topic" do
    @session.update!(active_topic: HouseholdFinance::ParticipantCare.topic(:crisis))
    assert_equal "crisis", @state.transition("i feel ashamed", reading("i feel ashamed", care: "shame", status: "ongoing"), history: []).fetch("care_kind")
    assert_equal "crisis", @state.transition("how much is left", reading("how much is left", status: "new_topic"), history: []).fetch("care_kind")
  end

  test "resolved acknowledgements retain a real crisis topic without a last question" do
    @session.update!(active_topic: HouseholdFinance::ParticipantCare.topic(:crisis))
    result = reading("thanks", status: "resolved")
    assert_equal "crisis", @state.transition("thanks", result, history: []).fetch("care_kind")
  end

  test "unlisted replies retain care without extending its deadline" do
    deadline = @state.active.fetch("expires_at")
    [ "how", "how?", "what?", "why", "?", "could you stay a moment" ].each do |text|
      assert_equal "grief", @state.transition(text, reading(text, status: "ongoing"), history: []).fetch("care_kind")
      assert_equal deadline, @state.active.fetch("expires_at")
    end
  end

  test "recovery and new topics release care and archive source restrictions" do
    [ "resolved", "new_topic" ].each do |status|
      @session.update!(active_topic: HouseholdFinance::ParticipantCare.topic(:grief))
      assert_nil @state.transition("all good now, we figured it out", reading("all good now, we figured it out", status: status), history: [])
      assert_empty @session.active_topic
      assert_equal "care", @session.open_topics.last.fetch("type")
    end
  end

  test "unavailable reader still recognizes an explicit recovery declaration" do
    text = "all good now, we figured it out"
    result = HouseholdFinance::ParticipantMessageReader.call(message: text, api_key: "")
    assert_nil @state.transition(text, result, history: [])
    assert_empty @session.active_topic
  end

  test "real financial questions release ongoing care without borrowing disclosure costs" do
    text = "Can I buy $40 shoes?"
    assert_nil @state.transition(text, reading(text, status: "ongoing"), history: [])
    assert_empty @session.active_topic
  end

  test "legacy care gets one fixed deadline rather than sliding on every reply" do
    @session.update!(active_topic: { "type" => "care", "title" => "Personal support", "care_kind" => "grief" })
    topic = @state.active
    assert topic["expires_at"].present?, "legacy care needs a persisted, fixed expiry"
    deadline = topic.fetch("expires_at")
    travel 1.day do
      @session.chat_messages.create!(role: "user", content: "ok")
      assert_equal deadline, @state.active.fetch("expires_at")
    end
    travel 3.days do
      assert_nil @state.active
    end
  end

  test "care expires after forty eight hours and is not revived weeks later" do
    [ 10, 20, 30 ].each do |days|
      @session.update!(active_topic: HouseholdFinance::ParticipantCare.topic(:grief))
      travel days.days do
        assert_nil @state.active
        assert_nil @state.transition("ok", reading("ok"), history: [])
      end
    end
  end
end
