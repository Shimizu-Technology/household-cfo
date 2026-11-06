require "test_helper"

class ParticipantMessageReaderTest < ActiveSupport::TestCase
  def object(facts: [], care: "none", field: "none", value: "", correction: false, preferences: [])
    { care: care, facts: facts, question: false, setup_answer: { field: field, value: value }, correction: correction, spending_preferences: preferences }
  end

  def fact(kind, amount, day: "today", merchant: "", item: "")
    { kind: kind, amount: amount, merchant: merchant, item: item, day: day }
  end

  def read(text, data, **options)
    HouseholdFinance::ParticipantMessageReader.call(message: text, transport: ->(_payload) { JSON.generate(data) }, **options)
  end

  test "R2 imperative analysis retains intent without changing a habit disclosure" do
    [ "look at my spending patterns", "analyze my spending habits" ].each do |message|
      assert read(message, object.merge(reply_intent: "spending_patterns")).available
      assert HouseholdFinance::MessageReplyIntent.matches?(message, "spending_patterns")
    end
  ensure
    HouseholdFinance::ParticipantMessageReader::Current.reset
  end

  test "an unasked habit disclosure cannot become a spending records question" do
    message = "i keep ordering gadgets when im tired"
    result = read(message, object.merge(reply_intent: "spending_patterns", question: false))
    assert result.available
    refute HouseholdFinance::MessageReplyIntent.matches?(message, "spending_patterns")
  ensure
    HouseholdFinance::ParticipantMessageReader::Current.reset
  end

  test "semantic reply intent is shared across reply paths and scoped to the exact message" do
    { "where could we trim things a bit" => "spending_patterns", "howd my first thirty days go" => "progress", "packed lunch the whole week woohoo" => "win" }.each do |message, intent|
      result = read(message, object.merge(reply_intent: intent, question: intent != "win"))
      assert result.available
      assert HouseholdFinance::MessageReplyIntent.matches?(message, intent)
      refute HouseholdFinance::MessageReplyIntent.matches?("another message", intent)
    end
    read("not sure", object)
    refute HouseholdFinance::MessageReplyIntent.matches?("not sure", "win")
  ensure
    HouseholdFinance::ParticipantMessageReader::Current.reset
  end

  test "structured facts keep savings spending and different days independent" do
    text = "cant believe i saved 20 today and 10 yesterday, spent 18 at shell today"
    result = read(text, object(facts: [ fact("set_aside", "20"), fact("set_aside", "10", day: "yesterday"), fact("purchase", "18", merchant: "shell") ]))
    assert result.available
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    intake = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: result)
    intake.call
    assert_equal [ 2000, 1000 ], intake.intakes.filter_map { |input| input[:amount_cents] }
    assert_equal [ Date.current.iso8601, Date.current.yesterday.iso8601 ], intake.intakes.first(2).pluck(:effective_on)
    assert_equal 1800, intake.intakes.last.dig(:purchases, 0, :amount_cents)
    assert_equal "shell", intake.intakes.last.dig(:purchases, 0, :merchant)
    assert_equal "shell", result.facts.last["merchant"]
    assert intake.intakes.all? { |input| input[:counted] == false && input[:approval_state] == "unreviewed_input" }
  end

  test "a condition after a completed report keeps the amount" do
    [ "saved 20 today even if it isnt much", "saved 20 if that counts", "even if i only saved 20 today thats something" ].each do |text|
      result = read(text, object(facts: [ fact("set_aside", "20", day: "") ]))
      assert_equal [ "20" ], result.facts.pluck("amount"), text
      assert_not result.hypothetical_movement, text
    end
    text = "saved 12 today would you count that"
    result = read(text, object(facts: [ fact("set_aside", "12") ]).merge(question: true))
    assert_equal [ "12" ], result.facts.pluck("amount")
    assert_equal [ "25" ], read("i saved 25 today and if i get overtime ill add more", object(facts: [ fact("set_aside", "25") ])).facts.pluck("amount")
  end

  test "a condition ahead of the amount stays hypothetical" do
    [ "if i put 100 away today would that be enough", "what if i saved 100" ].each do |text|
      result = read(text, object(facts: [ fact("set_aside", "100", day: "") ]).merge(question: true))
      assert_empty result.facts, text
      assert result.hypothetical_movement, text
    end
    result = read("would 100 be enough", object(facts: [ fact("set_aside", "100", day: "") ]).merge(question: true))
    assert_empty result.facts
  end

  test "an asked purchase stays a question even when the cash is said to be saved" do
    text = "Could I buy a $75 lunch bag? I saved that cash separately from my challenge savings."
    result = read(text, object(facts: [ fact("set_aside", "$75", day: "") ]).merge(question: true))
    assert_empty result.facts
    assert_not result.hypothetical_movement
    assert_equal [ "20" ], read("can i count the 20 i saved today", object(facts: [ fact("set_aside", "20") ]).merge(question: true)).facts.pluck("amount")
    assert_empty read("could i maybe just buy a $75 lunch bag", object(facts: [ fact("set_aside", "$75", day: "") ]).merge(question: true)).facts
    assert_equal [ "20" ], read("can i put down the 20 i deposited today", object(facts: [ fact("set_aside", "20") ]).merge(question: true)).facts.pluck("amount")
    assert_equal [ "20" ], read("saved 20 today, can i buy lunch", object(facts: [ fact("set_aside", "20") ]).merge(question: true)).facts.pluck("amount")
  end

  test "a stated report inside a question keeps its amount" do
    [ [ "could i put down that i saved 20 today", "20" ], [ "can i put down 30 i set aside friday", "30" ], [ "should i put the $10 i saved today with the rest", "$10" ] ].each do |text, amount|
      result = read(text, object(facts: [ fact("set_aside", amount, day: "") ]).merge(question: true))
      assert_equal [ amount ], result.facts.pluck("amount"), text
    end
  end

  test "reader shame is trusted except insults clearly aimed at things" do
    [ "this stupid budget", "dumb app", "my useless phone" ].each do |text|
      assert_equal "none", read(text, object(care: "shame")).care, text
    end
    [ "im so stupid with money", "i am really stupid", "im such a complete failure", "i hate myself for this", "I feel so ashamed of who I am." ].each do |text|
      assert_equal "shame", read(text, object(care: "shame")).care, text
    end
  end

  test "misplaced commas are never read as larger amounts" do
    { "saved 1,20 today" => "1,20", "saved 20,30 today" => "20,30", "saved 2,5000 today" => "2,5000", "saved 1200,50 today" => "1200,50" }.each do |text, amount|
      result = read(text, object(facts: [ fact("set_aside", amount) ]))
      assert_empty result.facts, text
      assert result.unclear_amount, text
    end
    assert_equal [ "$1,200" ], read("saved $1,200 today", object(facts: [ fact("set_aside", "$1,200") ])).facts.pluck("amount")
    assert_equal [ "1,200,000" ], read("saved 1,200,000 today", object(facts: [ fact("set_aside", "1,200,000") ])).facts.pluck("amount")
    assert_equal [ "20" ], read("put away 20, not much", object(facts: [ fact("set_aside", "20", day: "") ])).facts.pluck("amount")
    assert_empty read("saved 1,20 today", object(field: "income", value: "1,20"), setup_field: "primary_income").setup_answer["value"]
  end

  test "a disclosed grief cost is not purchase intake but explicit spending is retained" do
    text = "we buried my husband and the funeral cost 3200"
    assert_empty read(text, object(care: "grief", facts: [ fact("purchase", "3200", day: "") ])).facts
    text = "my husband died and i paid 3200 for his funeral"
    assert_equal 1, read(text, object(care: "grief", facts: [ fact("purchase", "3200", day: "") ])).facts.size
  end

  test "shame must describe the person rather than her budget" do
    assert_equal "none", read("im so done w this stupid budget lol", object(care: "shame")).care
    assert_equal "shame", read("im so stupid", object(care: "shame")).care
  end

  test "care keeps every reported amount and ordinary idioms do not become care" do
    text = "i lost my job but i still saved $20 today"
    reading = read(text, object(care: "hardship", facts: [ fact("set_aside", "$20") ]))
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: reading)
    parser.call
    assert_equal 2000, parser.intakes.sole[:amount_cents]
    HouseholdFinance::ParticipantMessageReader::Current.set(message: text, reading: reading) do
      assert_equal :hardship, HouseholdFinance::ParticipantCare.kind(text)
    end
    [ "my husband is dead set on a new truck", "i fired up the grill", "i lost my work phone", "i lost a bet at work", "my mom dead tired so i cooked" ].each do |message|
      assert_nil HouseholdFinance::ParticipantCare.kind(message), message
    end
  end

  test "malformed invented partial date and unquoted amounts fail closed" do
    [ "200", "2", "2026", "$20", "twenty" ].each do |amount|
      result = read("saved 20 today on 2026-11-06", object(facts: [ fact("set_aside", amount) ]))
      assert result.available, amount
      assert_empty result.facts
    end
    [ {}, object.merge(extra: true), object.merge(question: "false"), object(facts: [ fact("transfer", "20") ]), object.merge(facts: "20") ].each do |data|
      assert_equal data.empty? ? false : true, read("saved 20 today", data).available
    end
    assert_empty read("20 today", object(facts: [ fact("set_aside", "20", merchant: "Invented") ])).facts
  end

  test "setup values are quoted typed scoped and never invented" do
    reading = read("sorry i meant 4500", object(field: "income", value: "4500", correction: true), setup_field: "fixed_expenses", pending_field: "primary_income")
    assert reading.available
    assert_equal "primary_income", reading.answer_field
    assert_nil read("sorry i meant 4500", object(field: "income", value: "4500", correction: true), setup_field: "primary_income").answer_field
    assert_nil read("cruz", object(field: "name", value: "cruz family"), setup_field: "household_name").answer_field
    assert_nil read("rent 1400 power 200", object(field: "fixed", value: "1600"), setup_field: "fixed_expenses").answer_field
  end

  test "nothing saved cannot carry a negated amount into an accepted reading" do
    result = read("i havent saved 30 yet", object(facts: [ fact("nothing_saved", "30", day: "") ]))
    assert result.available
    assert_empty result.facts
  end

  test "outage accepts only clear anchored input and never guesses junk names or goals" do
    reader = HouseholdFinance::ParticipantMessageReader
    [ "idk", "lol", "asdf", "help", "hello", "not sure", "rent is 1400", "whats a good goal", "i dont have a goal", "ya", "k" ].each do |text|
      %w[household_name primary_goal].each do |field|
        result = reader.call(message: text, setup_field: field, api_key: "")
        assert_nil result.answer_field, text
        assert_empty result.facts
      end
    end
    assert_equal "$20", reader.call(message: "$20 set aside today", api_key: "").facts.sole["amount"]
    assert_equal "4500", reader.call(message: "4500", setup_field: "primary_income", api_key: "").setup_answer["value"]
    assert_empty reader.call(message: "cant believe i saved $40 today", api_key: "").facts
    assert_includes reader::OFF_REPLY, "try again"
  end

  test "zero savings never fabricates a no spend check in" do
    text = "I put aside $0 today"
    result = read(text, object(facts: [ fact("nothing_saved", "") ]))
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: result)
    parser.call
    assert_empty parser.intakes
  end

  test "a no spend question is not a report but a separate explicit report survives a question" do
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    text = "Was today a no-spend day"
    result = read(text, object.merge(question: true))
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: result)
    parser.call
    assert_empty parser.intakes

    text = "No spending today. What can I do tomorrow?"
    result = read(text, object.merge(question: true))
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: result)
    parser.call
    assert_equal true, parser.intakes.sole[:no_spend]
    assert_equal Date.current.iso8601, parser.intakes.sole[:local_on]
  end

  test "an outage never guesses that a no spend question reports a day" do
    text = "Was today a no-spend day"
    result = HouseholdFinance::ParticipantMessageReader.call(message: text, api_key: "")
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: result)
    parser.call
    assert_empty parser.intakes
  end

  test "quoted spoken cents are converted by the existing money normalizer" do
    text = "I spent eighteen dollars and forty-seven cents at Payless today"
    result = read(text, object(facts: [ fact("purchase", "eighteen dollars and forty-seven cents", merchant: "Payless") ]))
    assert result.available
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: result)
    parser.call
    assert_equal 1847, parser.intakes.sole.dig(:purchases, 0, :amount_cents)
  end

  test "an item is never promoted to an unknown merchant" do
    text = "bought lunch 12 today"
    result = read(text, object(facts: [ fact("purchase", "12", item: "lunch") ]))
    calendar = HouseholdFinance::PurchaseReportParser::Calendar.new(Date.current - 30, Date.current + 30, Date.current)
    parser = SavingsChallenge::ChatIntake.new(calendar, message: text, reading: result)
    parser.call
    assert_equal "", parser.intakes.sole.dig(:purchases, 0, :merchant)
  end

  test "care survives whitespace normalization between routing and narration" do
    text = "they  cut my hours"
    result = read(text, object(care: "hardship"))
    HouseholdFinance::ParticipantMessageReader::Current.set(message: text, reading: result) do
      assert_equal :hardship, HouseholdFinance::ParticipantCare.kind(text.squish)
    end
  end

  test "provider failure and denial follow the same outage contract without retries" do
    count = 0
    result = HouseholdFinance::ParticipantMessageReader.call(message: "saved 20 today", transport: ->(_payload) { count += 1; raise Net::ReadTimeout })
    refute result.available
    assert_equal 1, count
    with_mia_provider_capacity_rejected do |sites|
      result = read("saved 20 today", object)
      refute result.available
      assert_equal [ "participant_message_reader" ], sites
    end
  end

  test "preferences retain the reviewed participant choice and evidence" do
    text = "$2000 including groceries"
    preferences = [ { family: "groceries", group: "fixed", evidence: "including groceries" } ]
    result = read(text, object(field: "fixed", value: "$2000", preferences: preferences), setup_field: "fixed_expenses")
    assert result.available
    assert_equal "fixed", result.spending_preferences.sole["group"]
    assert_empty read(text, object(preferences: [ { family: "groceries", group: "fixed", evidence: "groceries go in bills" } ])).spending_preferences
  end
end
