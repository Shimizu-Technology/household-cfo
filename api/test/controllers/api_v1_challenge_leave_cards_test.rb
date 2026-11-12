require_relative "api_v1_pilot_leftovers_test"

class ApiV1ChallengeLeaveCardsTest < ApiV1PilotLeftoversTest
  def self.runnable_methods = public_instance_methods(false).map(&:to_s).grep(/\Atest_/)

  setup { enroll_in_challenge }

  def offer(message)
    body = say(message, legacy)
    assert_includes text(body), "Nothing has changed."
    body.fetch("challenge_chat_cards").find { |card| card["kind"] == "leave" }
  end

  def act(card, **fields)
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { expected_lock_version: card["lock_version"] }.merge(fields), headers: auth, as: :json
  end

  %w[leave pause].each do |intent|
    test "#{intent} creates no ticket until tapped and retries recover the same confirmation" do
      card = nil
      assert_no_difference "SetupSupportRequest.count" do
        card = offer("I want to #{intent} the challenge because this takes too much time")
      end
      assert_equal [ intent ], card.dig("input", "intents")
      assert_equal "active", @savings_enrollment.reload.status
      get "/api/v1/savings_challenge/chat_cards", headers: auth
      assert_response :success
      assert_includes response.parsed_body["records"].map { |row| row["id"] }, card["id"]
      act(card, action: "request_leave", intent: intent)
      assert_response :unprocessable_entity
      assert_no_difference "SetupSupportRequest.count" do
        act(card, action: "request_leave", intent: intent == "leave" ? "pause" : "leave", accepted: true)
        assert_response :unprocessable_entity
      end
      assert_difference "SetupSupportRequest.count", 1 do
        act(card, action: "request_leave", intent: intent, accepted: true)
        assert_response :success
      end
      result = response.parsed_body
      act(card, action: "request_leave", intent: intent)
      assert_response :unprocessable_entity, "even a replay requires the explicit choice"
      ticket = SetupSupportRequest.last
      assert_equal [ "leave_challenge", intent ], [ ticket.reason, ticket.leave_intent ]
      assert_equal "I asked to #{intent} the challenge", SetupHelp::Serializer.request(ticket)[:reason_label]
      assert_includes result.dig("assistant_message", "content"), "I've let your coach know you'd like to #{intent}"
      assert_equal "active", @savings_enrollment.reload.status
      assert_no_difference [ "SetupSupportRequest.count", "ChatMessage.count" ] do
        act(card, action: "request_leave", intent: intent, accepted: true)
        assert_response :success
        assert_equal result, response.parsed_body
      end
    end
  end

  test "not now closes only the card and veto retracts an earlier pending card" do
    card = offer("How do I quit the challenge?")
    assert_no_difference "SetupSupportRequest.count" do
      act(card, action: "dismiss")
      assert_response :success
    end
    card = offer("Please pause the challenge")
    body = say("Don't tell my coach I want to pause the challenge", legacy)
    assert_equal [ [ card["id"], "closed" ] ], body["challenge_chat_cards"].map { |row| row.values_at("id", "status") }
    assert_equal "closed", SavingsChatCard.find(card["id"]).status
    assert_no_difference "SetupSupportRequest.count" do
      act(card, action: "request_leave", intent: "pause", accepted: true)
      assert_response :conflict
    end
  end

  test "question and reminders get both answers and card without notification" do
    assert_no_difference "SetupSupportRequest.count" do
      card = offer("I want to quit the challenge, should I?")
      assert_equal [ "leave" ], card.dig("input", "intents")
      body = say("I want to quit the challenge and turn off reminders", legacy)
      assert_includes text(body), "turn off the reminders"
      assert_includes text(body), "stop your daily check-ins"
      assert_equal [ "leave" ], body["challenge_chat_cards"].last.dig("input", "intents")
    end
  end

  test "failed turn persistence cannot create a ticket or leave an orphan card" do
    model = ChatMessage
    original = model.instance_method(:save!)
    model.define_method(:save!) { |**| raise ActiveRecord::RecordInvalid.new(self) }
    assert_no_difference [ "SetupSupportRequest.count", "SavingsChatCard.count" ] do
      post "/api/v1/mia/messages", params: { message: "I want to leave the challenge" }, headers: auth, as: :json
      assert_response :unprocessable_entity
    end
  ensure
    model.define_method(:save!, original)
  end

  test "failed confirmation persistence rolls back the ticket and allows an exact retry" do
    card = offer("I want to pause the challenge")
    model = ChatMessage
    original = model.instance_method(:save!)
    model.define_method(:save!) { |**| raise ActiveRecord::RecordInvalid.new(self) }
    assert_no_difference "SetupSupportRequest.count" do
      act(card, action: "request_leave", intent: "pause", accepted: true)
      assert_response :unprocessable_entity
    end
    assert_equal "pending", SavingsChatCard.find(card["id"]).status
    model.define_method(:save!, original)
    act(card, action: "request_leave", intent: "pause", accepted: true)
    assert_response :success
    assert_equal 1, SetupSupportRequest.count
  ensure
    model.define_method(:save!, original)
  end

  test "crisis prevents a pending card from notifying the coach" do
    card = offer("I want to leave the challenge")
    say("I want to kill myself. I have a gun.", legacy(care: "crisis"))
    assert_no_difference "SetupSupportRequest.count" do
      act(card, action: "request_leave", intent: "leave", accepted: true)
      assert_response :unprocessable_entity
    end
  end

  test "a challenge partner can explicitly send a pause without setup restart access" do
    @household.household_memberships.find_by!(user: @user).update!(role: "partner")
    card = offer("I want to pause the challenge")
    act(card, action: "request_leave", intent: "pause", accepted: true)
    assert_response :success
    assert_equal "pause", SetupSupportRequest.last.leave_intent
    post "/api/v1/setup_help/requests", params: { reason: "other", share_metadata: true }, headers: auth.merge("Idempotency-Key" => "partner-no-setup"), as: :json
    assert_response :forbidden
  end

  test "participant-editable daily card state cannot expose another conversation's message" do
    card = offer("I want to leave the challenge")
    daily = SavingsChatCard.find(card["id"])
    daily.update!(kind: "daily_report")
    stranger = User.create!(clerk_id: "private-#{SecureRandom.hex(8)}", email: "private-#{SecureRandom.hex(8)}@example.invalid", role: "participant", invitation_status: "accepted")
    household = HouseholdFinance::WorkspaceResolver.new(stranger).household
    private_session = household.chat_sessions.create!(user: stranger)
    secret = private_session.chat_messages.create!(role: "assistant", content: "Private conversation must never be returned")
    act(daily.as_api_json.deep_stringify_keys, action: "save_state", state: { phase: "idle", assistant_message_id: secret.id })
    assert_response :success
    assert_nil response.parsed_body["assistant_message"]
    refute_includes response.body, secret.content
  end

  test "mixed challenge calendar and rent question explicitly answers the unknown rent date" do
    body = say("When does my challenge end, and when is my rent due?", legacy(question: true))
    assert_includes text(body), "Your challenge runs from"
    assert_includes text(body), "I don't have your rent due date"
  end
end
