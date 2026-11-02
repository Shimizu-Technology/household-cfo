require "test_helper"
require_relative "../support/persona_test_helper"

class HouseholdFinanceMiaReviewTwoTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "category followup normalizes articles category suffix and politeness to an existing name" do
    [ "Put it under the Fixed essentials category.", "Put it in my fixed ESSENTIALS category please!",
      "Please put it under our Fixed essentials please" ].each do |message|
      result = resolver(message, pending_context).call
      assert_equal "Fixed essentials", result.action[:category_name], message
      assert_equal "update_transaction_draft", result.action[:type]
    end
  end

  test "unknown category followup is never silently carried unless explicitly new" do
    [ "Put it under Imaginary category.", "Put it under a new category", "Put it under Brand New Clothes category" ].each do |message|
      assert_nil resolver(message, pending_context).send(:deterministic_category_followup_result), message
    end
    result = resolver("Put it under the new Cigarettes category please", pending_context).call
    assert_equal "Cigarettes", result.action[:category_name]
    result = resolver("Put it in a new category Cigarettes please", pending_context).call
    assert_equal "Cigarettes", result.action[:category_name]
  end

  test "new is retained when it belongs to the category name" do
    context = pending_context
    context[:budget_categories] += [ { id: 3, name: "New Car" }, { id: 4, name: "My Travel" }, { id: 5, name: "Travel" } ]
    assert_equal "New Car", resolver("Put it under the New Car category", context).call.action[:category_name]
    assert_equal "My Travel", resolver("Put it under the My Travel category please", context).call.action[:category_name]
    assert_equal "New Clothes", resolver("Put it under a new New Clothes category", pending_context).call.action[:category_name]
  end

  test "new category validation rejects incidental substrings and partial existing names" do
    {
      [ "I spent $12 at Payless", "Pay" ] => false,
      [ "Put it at Payless in a category", "at" ] => false,
      [ "Put it under Dining", "Dining" ] => false,
      [ "Put it under Dining category", "Dining" ] => false,
      [ "Put it in a new Cigarettes category", "Cigarettes" ] => true,
      [ "Put it in the Cigarettes category", "Cigarettes" ] => true,
      [ "Create a new Dining category", "Dining" ] => true,
      [ "Use Dining Out", "Dining Out" ] => true
    }.each do |(message, name), expected|
      assert_equal expected, resolver(message, pending_context).send(:valid_review_category?, 0, name), "#{message}: #{name}"
    end
  end

  test "incidental when where and confirmed purchase chatter cannot duplicate a purchase" do
    [ "Put it somewhere safe", "Review whenever you like", "Apply when you are ready" ].each do |assistant|
      context = { conversation: { recent_messages: [
        { role: "user", content: "I spent $60 at Ross today" },
        { role: "assistant", content: assistant }
      ] } }
      assert_nil resolver("It was great", context).send(:deterministic_purchase_continuation_result), assistant
    end
    context = { conversation: { recent_messages: [
      { role: "user", content: "I spent money at Ross today" },
      { role: "assistant", content: "How much did you spend?" }
    ] } }
    assert_equal "create_transaction_draft", resolver("It was $60", context).send(:deterministic_purchase_continuation_result).action[:type]
  end

  test "participant conflicts resolves each cohort once across many participants" do
    coach = persona_user
    first = cohort_for(coach, name: "First")
    second = cohort_for(coach, name: "Second")
    4.times do
      participant = persona_user(role: "participant")
      [ first, second ].each { |cohort| cohort.cohort_memberships.create!(user: participant, role: "participant") }
    end
    original = Mia::PersonaResolver.method(:selection_for)
    calls = []
    Mia::PersonaResolver.define_singleton_method(:selection_for) do |cohort|
      calls << cohort.id
      original.call(cohort)
    end
    assert_empty CohortReleases::ParticipantConflicts.new(cohort: first).entries
    assert_equal [ first.id, second.id ].sort, calls.sort
  ensure
    Mia::PersonaResolver.define_singleton_method(:selection_for, original) if original
  end

  test "reflection packet records provenance without claiming verified financial outcomes" do
    packet = HouseholdFinance::MiaAnswerPacketBuilder.new(kind: "coaching", fallback_response: "What worked?",
      write_state: "no_write", participant_message: "I stayed under my budget", reflection: true).call
    assert_includes packet[:basis], "participant-reported"
    assert_equal "not established by this report", packet.dig(:coaching_provenance, :financial_effect)
    assert_nil packet[:annual_plan_summary]
  end

  test "mixed month writes continue to normal action routing" do
    [ "How am I doing this month — and change my salary to $6,400",
      "How am I doing this month? My salary is $6,400 now",
      "How am I doing this month? Change Groceries to $700",
      "How am I doing this month? Rename Groceries category to Food" ].each do |message|
      assert_nil resolver(message, {}).send(:deterministic_coaching_result), message
    end
    assert_nil resolver("Should I change my salary to $6,400?", {}).send(:deterministic_current_salary_result)
  end

  test "essentials also precede deposit boundaries and purchase clarification beside a month question" do
    [ "I can't pay rent. I put $50 in savings",
      "I skipped lunch to save. I put $50 in savings",
      "I spent money at Ross. I can't afford food. How am I doing this month?" ].each do |message|
      result = resolver(message, {}).call
      assert_equal "coaching", result.intent, message
      refute result.actionable?, message
      refute result.clarification?, message
    end
  end

  test "all nonamount proposal types use neutral wording and remain unapplied" do
    builder = HouseholdFinance::MiaActionDraftBuilder.allocate
    %w[rename_category reclassify_category archive_category restore_category].each do |type|
      response = builder.send(:proposal_response, "Prepared for review.", type)
      assert_includes response, "Check the details"
      assert_includes response, "nothing changes until you apply"
      refute_includes response, "amount and timing"
    end
  end

  private

  def resolver(message, context)
    HouseholdFinance::MiaIntentResolver.new(user_message: message, context: context, api_key: "")
  end

  def pending_context
    { budget_categories: [ { id: 1, name: "Fixed essentials" }, { id: 2, name: "Dining Out" } ],
      pending_transaction_reviews: [ { id: 7, merchant: "Payless", splits: [] } ] }
  end
end
