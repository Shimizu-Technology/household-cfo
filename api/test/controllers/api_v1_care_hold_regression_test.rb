require_relative "api_v1_crisis_path_safety_test"

class ApiV1CareHoldRegressionTest < ApiV1CrisisPathSafetyTest
  def self.runnable_methods = public_instance_methods(false).map(&:to_s).grep(/\Atest_/)

  HEDGES = [ "I'm safe now I think", "I'm okay now, probably", "I'm safe now, sort of", "I'm ok now idk",
    "I am safe, not sure for how long", "I'm okay now though", "I'm safe now... I hope", "I am safe-ish",
    "I'm safe now unless tonight gets bad" ].freeze

  def with_resolved_reader
    reader = HouseholdFinance::ParticipantMessageReader
    original = reader.method(:call)
    data = legacy(care_status: "resolved")
    reader.define_singleton_method(:call) { |**options| original.call(**options.merge(transport: ->(_) { JSON.generate(data) })) }
    yield
  ensure
    reader.define_singleton_method(:call, original)
  end

  %i[household challenge].each do |mode|
    %i[off on timeout resolved].each do |model|
      HEDGES.each do |message|
        test "#{mode} #{model} allows no recovery outside the whole-message list: #{message}" do
          enroll_in_challenge if mode == :challenge
          say(GUN, legacy(care: "crisis"))
          run = -> { raw(message) }
          body = case model
          when :off then run.call
          when :resolved then with_resolved_reader { run.call }
          else with_reader_timeout(available: model == :on) { run.call }
          end
          assert_crisis(body)
          refute_includes text(body), "glad you're safe"
          assert_crisis(raw("I haven't moved it yet."))
          assert_includes session.reload.active_topic.to_json, GUN
        end
      end
    end

    [ "I'm safe now", "I'm safe now, thanks", "I'm ok now, thank you", "I'm safe. thanks" ].each do |message|
      test "#{mode} accepts whole-message recovery #{message}" do
        enroll_in_challenge if mode == :challenge
        say(GUN, legacy(care: "crisis"))
        assert_equal "I'm glad you're safe. 988 is there any time, day or night.", text(raw(message))
        assert_nil HouseholdFinance::ParticipantCareState.new(session.reload).active
        assert_empty session.care_hold
      end
    end

    %w[current all].each do |picture|
      test "#{mode} #{picture} deletion retains care independent of topic writes and erases disclosure" do
        enroll_in_challenge if mode == :challenge
        say("Zebra9 private detail. #{GUN}", legacy(care: "crisis"))
        hold = session.reload.active_topic.slice("type", "care_kind", "started_at", "expires_at")
        delete "/api/v1/mia/messages", params: { picture: picture }, headers: auth
        assert_response :no_content
        assert_equal hold, session.reload.care_hold
        assert_empty session.active_topic
        session.update!(active_topic: { type: "setup_card", field: "household_name" })
        assert_equal "setup_card", session.reload.active_topic["type"]
        assert_equal "crisis", HouseholdFinance::ParticipantCareState.new(session).active["care_kind"]
        assert_empty session.chat_messages
        assert_empty session.open_topics
        assert_nil session.rolling_summary
        refute_match(/Zebra9|gun|private detail/, session.attributes.to_json)
        body = raw("I haven't moved it yet.")
        assert_includes text(body), "988"
        assert_includes text(body), "Put distance between you and anything you could use to hurt yourself"
        assert_crisis(raw("I'm okay now but I still have the gun"))
        travel 49.hours do
          assert_nil HouseholdFinance::ParticipantCareState.new(session.reload).active
          session.update!(active_topic: { type: "setup_card", field: "household_name" })
          assert_equal "setup_card", session.reload.active_topic["type"]
        end
      end
    end
  end

  %i[paused closed].each do |status|
    test "#{status} challenge answers existing crisis first without saving" do
      enroll_in_challenge
      say(GUN, legacy(care: "crisis"))
      @savings_cohort.update!(status == :paused ? { savings_challenge_release_hold: true } : { status: "draft", savings_challenge_enabled: false })
      original = session.reload.attributes
      [ "I haven't moved it yet.", "I'm okay now but I still have the gun", "the gun is still loaded", "ok", "I can't pay my rent" ].each do |message|
        assert_no_difference [ "ChatMessage.count", "SavingsChatCard.count", "SavingsEntryDraft.count", "SetupSupportRequest.count" ] do
          body = raw(message)
          assert_equal false, body["conversation_persisted"]
          assert_crisis(body)
        end
        assert_equal original, session.reload.attributes
      end
    end
  end

  test "new urgent food disclosure replaces stale grief narration and its last question" do
    say("my mom just died", legacy(care: "grief"))
    narrator = HouseholdFinance::MiaNarrator
    original = narrator.instance_method(:call)
    other = open_session
    headers = auth
    fired = false
    narrator.define_method(:call) do
      unless fired
        fired = true
        other.post "/api/v1/mia/messages", params: { message: "we have no food money" }, headers: headers, as: :json
      end
      "I'm sorry about your mom. Who can sit with you?"
    end
    body = raw("could you stay a moment")
    assert_equal 201, other.response.status
    assert_includes text(body), "Food comes first"
    refute_includes text(body), "mom"
    assert_equal "food", session.reload.active_topic["care_kind"]
    assert_equal text(body).last(700), session.active_topic["last_question"]
  ensure
    narrator.define_method(:call, original)
  end

  test "non-care narration finishing after crisis never saves the prepared financial answer" do
    narrator = HouseholdFinance::MiaNarrator
    original = narrator.instance_method(:call)
    other = open_session
    headers = auth
    narrator.define_method(:call) do
      other.post "/api/v1/mia/messages", params: { message: ApiV1CrisisPathSafetyTest::GUN }, headers: headers, as: :json
      "Your money focus is to save $50."
    end
    assert_crisis(raw("What should I focus on with my money this month?"))
    refute session.chat_messages.exists?(content: "Your money focus is to save $50.")
    assert_equal session.chat_messages.order(:id).last.content, session.active_topic["last_question"]
  ensure
    narrator.define_method(:call, original)
  end
  test "an older paged safety reply cannot resurrect a completed care hold" do
    first_reply_id = nil
    travel_to 6.days.ago do
      first_reply_id = say(GUN, legacy(care: "crisis")).dig("assistant_message", "id")
      raw("I'm safe now, thanks")
    end
    travel_to 3.days.ago do
      say(GUN, legacy(care: "crisis"))
    end
    assert_nil HouseholdFinance::ParticipantCareState.new(session.reload).active
    raw("Help me set up my household")
    get "/api/v1/mia/messages", params: { before_id: first_reply_id + 1 }, headers: auth
    assert_response :success
    page = response.parsed_body
    assert_equal first_reply_id, page["messages"].last["id"]
    assert_equal true, page["messages"].last["safety_reply"]
    assert_equal false, page["care_hold"]
  end

  test "privacy deletion leaves no disclosure text in any stored text or JSON column" do
    say("Zebra9 private detail. #{GUN}", legacy(care: "crisis"))
    delete "/api/v1/mia/messages", params: { picture: "all" }, headers: auth
    assert_response :no_content
    connection = ActiveRecord::Base.connection
    hits = connection.tables.filter_map do |table|
      columns = connection.columns(table).select { |column| column.type.in?(%i[string text json jsonb]) }
      next if columns.empty?
      condition = columns.map { |column| "#{connection.quote_column_name(column.name)}::text ILIKE '%Zebra9%'" }.join(" OR ")
      table if connection.select_value("SELECT EXISTS (SELECT 1 FROM #{connection.quote_table_name(table)} WHERE #{condition})")
    end
    assert_empty hits
    assert_equal "crisis", session.reload.care_hold["care_kind"]
  end
  test "a stale care topic writer cannot downgrade the private crisis hold" do
    say(GUN, legacy(care: "crisis"))
    delete "/api/v1/mia/messages", headers: auth
    assert_response :no_content
    session.update!(active_topic: HouseholdFinance::ParticipantCare.topic(:grief))
    assert_equal "crisis", HouseholdFinance::ParticipantCareState.new(session.reload).active["care_kind"]
    body = raw("ok")
    assert_includes text(body), "988"
    assert_includes text(body), "Put distance"
  end

  test "deletion followed by recovery allows a real setup continuation" do
    say(GUN, legacy(care: "crisis"))
    delete "/api/v1/mia/messages", headers: auth
    assert_response :no_content
    raw("I'm safe now, thanks")
    say("Help me set up my household", read)
    body = say("Call our household Taitano", read(setup: changes(household_name: "Taitano")))
    card = card_of(body)
    assert card
    assert_equal "Taitano", card.dig("setup_card", "rows").find { |row| row["key"] == "household_name" }["value_text"]
    assert_equal "household_setup", session.reload.active_topic["type"]
    assert_nil HouseholdFinance::ParticipantCareState.new(session).active
  end

  test "migration rollback refuses to discard a private crisis hold after deletion" do
    require Rails.root.join("db/migrate/20261112110000_preserve_private_care_holds")
    say(GUN, legacy(care: "crisis"))
    delete "/api/v1/mia/messages", headers: auth
    assert_response :no_content
    assert_raises(ActiveRecord::IrreversibleMigration) do
      ActiveRecord::Migration.suppress_messages { PreservePrivateCareHolds.new.migrate(:down) }
    end
    assert_equal "crisis", session.reload.care_hold["care_kind"]
  end
end
