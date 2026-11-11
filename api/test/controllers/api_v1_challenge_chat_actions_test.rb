require "test_helper"
require_relative "../support/participant_reader_test_support"
require_relative "../support/savings_daily_test_support"

# Approving a saving and joining the challenge from the chat card, with the
# same operations and guards the Savings and join screens use.
class ApiV1ChallengeChatActionsTest < ActionDispatch::IntegrationTest
  include ParticipantReaderTestSupport
  include SavingsDailyTestSupport

  setup do
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 11, 30, 12)
    setup_savings_context
    @old_key = ENV["OPENROUTER_API_KEY"]
    ENV["OPENROUTER_API_KEY"] = ""
  end

  teardown do
    ENV["OPENROUTER_API_KEY"] = @old_key
    travel_back
  end

  def auth = { "Authorization" => "Bearer test_token_#{@savings_user.id}", "X-Cohort-Id" => @savings_cohort.id.to_s }

  def ask(message, request_id = SecureRandom.hex(6))
    post "/api/v1/mia/messages", params: { message: message, request_id: request_id }, headers: auth, as: :json
    assert_response :created
    response.parsed_body
  end

  def act(card, **fields)
    post "/api/v1/savings_challenge/chat_cards/#{card['id']}", params: { expected_lock_version: card["lock_version"] }.merge(fields), headers: auth, as: :json
  end

  def reported = SavingsChallenge::Projection.new(@savings_enrollment.reload).call[:reported_cents]

  test "a saving is approved in the card with the same checks as Savings Home" do
    with_savings_runtime { savings_enroll }
    card = ask("I set aside $25 today").fetch("challenge_chat_card")
    assert_equal "savings", card["kind"]
    assert_nil reported

    act(card, action: "approve_savings", accepted: true)
    assert_response :unprocessable_entity, "the new-money confirmation is required"
    assert_includes response.parsed_body["errors"].first, "new money"
    assert_nil reported

    act(card, action: "approve_savings", accepted: true, new_money_confirmed: true)
    assert_response :success
    assert_equal "closed", response.parsed_body.dig("record", "status")
    assert_equal 2_500, reported
    assert_equal 2_500, response.parsed_body.dig("challenge", "projection", "reported_cents")
    version = SavingsEntryVersion.last
    assert_equal [ 2_500, "new_money_reserved" ], [ version.signed_cents, version.funding_source ]
    assert_equal 1, SavingsEntryVersion.count

    act(card, action: "approve_savings", accepted: true, new_money_confirmed: true)
    assert_response :success, "approving the same card again replays"
    assert_equal 1, SavingsEntryVersion.count
  end

  test "a withdrawal needs no new-money confirmation and a correction replaces the amount" do
    with_savings_runtime { savings_enroll }
    with_savings_runtime { savings_approve(savings_draft(2_000)) }
    card = ask("I withdrew $5 from savings today").fetch("challenge_chat_card")
    act(card, action: "approve_savings", accepted: true)
    assert_response :success
    assert_equal 1_500, reported

    fix = ask("Actually the $20 I set aside was really $15").fetch("challenge_chat_card")
    assert_equal 2_000, fix.dig("input", "correction", "current_approved_version", "signed_cents")
    act(fix, action: "approve_savings", accepted: true)
    assert_response :success
    assert_equal 1_000, reported, "$15 replaces the $20, then the $5 comes out"
  end

  test "a saving needs her Yes, a stale card refuses, and a card from another step is not approved" do
    with_savings_runtime { savings_enroll }
    card = ask("I set aside $25 today").fetch("challenge_chat_card")
    act(card, action: "approve_savings", new_money_confirmed: true)
    assert_response :unprocessable_entity
    act(card.merge("lock_version" => card["lock_version"] + 3), action: "approve_savings", accepted: true, new_money_confirmed: true)
    assert_response :conflict
    assert_nil reported

    goal = ask("Set my goal to $300").fetch("challenge_chat_card")
    act(goal, action: "approve_savings", accepted: true, new_money_confirmed: true)
    assert_response :unprocessable_entity
    assert_equal 0, SavingsEntryVersion.count
  end

  test "a correction card whose saved amount changed since is refused, and nothing is saved" do
    with_savings_runtime { savings_enroll }
    entry = nil
    with_savings_runtime do
      saved = savings_approve(savings_draft(2_000))
      entry = SavingsEntry.find(saved.savings_entry_id)
    end
    fix = ask("Actually the $20 I set aside was really $15").fetch("challenge_chat_card")
    assert_equal 2_000, fix.dig("input", "correction", "current_approved_version", "signed_cents")

    # Before she answers, the approved amount changes somewhere else (the Savings screen).
    with_savings_runtime { savings_approve(savings_draft(1_800, entry: entry)) }
    assert_equal 1_800, reported

    act(fix, action: "approve_savings", accepted: true)
    assert_includes [ 409, 422 ], response.status
    assert_equal 1_800, reported, "the old card cannot overwrite the newer amount"
    assert_equal 2, SavingsEntryVersion.where(savings_entry_id: entry.id).count
  end

  test "asking to join explains and offers the join card, and the join screen's call enrolls" do
    with_savings_runtime { }
    body = ask("I want to join")
    assert body["challenge_join"]
    assert_includes body.dig("assistant_message", "content"), "Nothing happens until you check the box and tap Accept and join"
    assert_nil SavingsEnrollment.find_by(user: @savings_user, cohort: @savings_cohort)
    get "/api/v1/savings_challenge", headers: auth
    offer = response.parsed_body.fetch("offer")
    assert offer["accepting_enrollments"]

    post "/api/v1/savings_challenge/enrollment", params: { participation_accepted: true, policy_version: offer["policy_version"], late_start_accepted: offer["late_start_acceptance_required"] == true, expected_acceptance_digest: offer["acceptance_digest"] },
      headers: auth.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success
    assert SavingsEnrollment.find_by(user: @savings_user, cohort: @savings_cohort)

    again = ask("how do I join?")
    refute again["challenge_join"]
    assert_includes again.dig("assistant_message", "content"), "You're already in"
  end

  test "joining is not offered while the group is not open, and quitting questions are not join requests" do
    with_savings_runtime { }
    @savings_cohort.update!(savings_challenge_release_hold: true)
    body = ask("I want to join the challenge")
    refute body["challenge_join"]
    assert_includes body.dig("assistant_message", "content"), "paused"

    @savings_cohort.update!(savings_challenge_release_hold: false)
    body = ask("how do I quit the challenge?")
    refute body["challenge_join"]
  end

  test "the progress answer points to the checkpoint card once a checkpoint is due" do
    with_savings_runtime { savings_enroll }
    travel_to Time.find_zone!("Pacific/Guam").local(2026, 12, 31, 12)
    body = ask("how am I doing")
    assert_match(/Day 30 is ready to review/, body.dig("assistant_message", "content"))
    assert_match(/card below/, body.dig("assistant_message", "content"))
  end
end
