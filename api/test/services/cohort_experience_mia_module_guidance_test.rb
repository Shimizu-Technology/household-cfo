# frozen_string_literal: true

require "test_helper"

class CohortExperienceMiaModuleGuidanceTest < ActiveSupport::TestCase
  test "model context includes every enabled and disabled module without prohibiting money topics" do
    guidance = guidance_for(%w[statements])
    assert_equal %w[home ask_mia statements], guidance.context.fetch(:enabled)
    assert_equal %w[review budget profile wealth cfo_filter optionality], guidance.context.fetch(:disabled)
    assert_includes guidance.context.fetch(:safety_note), "supervised reviews in chat"
    assert_includes guidance.context.fetch(:safety_note), "does not prohibit discussing"
  end

  test "legacy Profile retains its implicit Statements destination for model suggestions" do
    legacy = CohortExperience::EffectiveCapabilitiesResolver.safe_default_payload(cohort_membership: nil, standalone: true)
    original = legacy.deep_dup
    guidance = CohortExperience::MiaModuleGuidance.new(legacy)
    assert_includes guidance.context.fetch(:enabled), "statements"
    refute_includes guidance.context.fetch(:disabled), "statements"
    assert_equal "Open Statements.", guidance.filter("Open Statements.")
    assert_equal original, legacy
  end

  test "existing model system prompts receive trusted module rules without changing the persona" do
    original = Mia::Persona.neutral
    prompt = original.system_prompt.dup
    guided = guidance_for(%w[statements]).persona(original)
    assert_includes guided.system_prompt, prompt
    assert_includes guided.system_prompt, "only recommend enabled destinations"
    assert_includes guided.system_prompt, '"disabled":["review","budget","profile","wealth","cfo_filter","optionality"]'
    assert_includes guided.system_prompt, '"enabled":["home","ask_mia","statements"]'
    assert_equal original.name, guided.name
    assert_equal original.data, guided.data
    assert_equal prompt, original.system_prompt
  end

  test "disabled navigation suggestions are redirected but verified financial facts remain" do
    guidance = guidance_for([])
    [ 'Open "Wealth"', "Open Review", "Go to Transactions", "Open Budget", "Visit My Profile", "Switch to My Money", "Open Wealth",
      "Finish Manual setup", "Open Statements", "Go to Files", "Use CFO Filter", "Try Optionality", "Upload a statement in Statements" ].each do |suggestion|
      filtered = guidance.filter("Your approved savings are $500. #{suggestion}.")
      assert_includes filtered, "Your approved savings are $500."
      refute_includes filtered, suggestion
      assert_includes filtered, "here in chat"
    end
    assert_includes guidance.filter("Review your $500 debt in Statements."), "$500"
    facts = "Your budget is $500. Review the $20 purchase here before approving. Wealth can mean having choices."
    assert_equal facts, guidance.filter(facts)
    assert_equal "Open Statements.", guidance_for(%w[statements]).filter("Open Statements.")
    assert_equal "Open My Profile.", guidance_for(%w[profile]).filter("Open My Profile.")
  end

  test "all message writer paths filter text and structured presentation before saving" do
    user = User.create!(clerk_id: "module-writer", email: "module-writer@example.invalid", role: "participant", invitation_status: "accepted")
    household = Household.create!(name: "Module writer household", created_by_user: user)
    session = ChatSession.create!(user: user, household: household)
    runtime = Struct.new(:capabilities, :cohort_id, :release_id).new(capabilities([]), nil, nil)
    writer = CohortExperience::AssistantMessageWriter.new(session: session, persona: Mia::Persona.neutral, participant_runtime: runtime)
    built = writer.build(content: "Open Wealth. Your approved savings are $500.", presentation: {})
    refute_includes built.content, "Open Wealth"
    assert_includes built.content, "$500"
    bounded = writer.build(content: "Open Wealth. " * ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH)
    assert_operator bounded.content.length, :<=, ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH
    presentation = { version: 1, kind: "read_only_answer", basis: "saved_household",
      lead: "Open Wealth. Your approved savings are $500.",
      sections: [ { id: "part-1", title: "Next step", body: "Open Statements. Your approved savings are $500." } ] }
    saved = writer.create!(content: "Open Statements.", presentation: presentation)
    refute_includes saved.reload.content, "Open Statements"
    refute saved.new_record?
    serialized = saved.as_api_json.fetch(:presentation)
    assert_equal "Keep working with me here in chat. Your approved savings are $500.", serialized.fetch("lead")
    assert_equal "Keep working with me here in chat. Your approved savings are $500.", serialized.fetch("sections").sole.fetch("body")
    assert_equal({ direct_answer: "Keep working with me here in chat.", amount: 500 }, guidance_for([]).filter({ direct_answer: "Open Wealth.", amount: 500 }))
  end

  private

  def capabilities(enabled)
    config = CohortExperience::Schema.upgrade(CohortExperience::Schema::DEFAULT_CONFIG)
    config["optional_modules"] = CohortExperience::Schema::CONFIGURABLE_MODULES.index_with { |id| enabled.include?(id) }
    CohortExperience::EffectiveCapabilitiesResolver.payload_for(config: config, source: "test", cohort_membership: nil, version: nil)
  end

  def guidance_for(enabled)
    CohortExperience::MiaModuleGuidance.new(capabilities(enabled))
  end
end
