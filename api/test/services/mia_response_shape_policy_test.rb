# frozen_string_literal: true

require "test_helper"

class MiaResponseShapePolicyTest < ActiveSupport::TestCase
  PersonaStub = Struct.new(:version_id, :response_shape)

  setup do
    @persona = PersonaStub.new(
      42,
      {
        "min_sentences" => 2,
        "max_sentences" => 3,
        "max_characters" => 120,
        "plain_text_only" => true
      }
    )
  end

  test "accepts provider output within every configured shape bound" do
    assert Mia::ResponseShapePolicy.valid?("Review the plan first. Then choose one next move.", persona: @persona)
  end

  test "rejects output outside sentence character or plain text bounds" do
    refute Mia::ResponseShapePolicy.valid?("Only one sentence.", persona: @persona)
    refute Mia::ResponseShapePolicy.valid?("First sentence. #{'x' * 120}.", persona: @persona)
    refute Mia::ResponseShapePolicy.valid?("**Review the plan.** Then choose one move.", persona: @persona)
    refute Mia::ResponseShapePolicy.valid?("Review these items.\n- Check the plan.", persona: @persona)
  end

  test "does not mistake ordinary inline punctuation for markdown" do
    assert Mia::ResponseShapePolicy.valid?("The adjustment is - $300. Review the plan next.", persona: @persona)
    assert Mia::ResponseShapePolicy.valid?("Choose option 3. Review the plan next.", persona: @persona)
  end

  test "does not impose custom shape rules on the global fallback persona" do
    global_persona = Object.new

    assert Mia::ResponseShapePolicy.valid?("One sentence.", persona: global_persona)
  end

  test "coach honorifics do not create false sentence boundaries" do
    assert Mia::ResponseShapePolicy.valid?("Mrs. Mel asks you to review the plan. Choose one next move.", persona: @persona)
    refute Mia::ResponseShapePolicy.valid?("Mrs. Mel guides the plan.", persona: @persona)
    refute Mia::ResponseShapePolicy.valid?("Mrs. Mel guides you. Review the plan. Compare actuals. Choose one move.", persona: @persona)
  end
  [
    "Review essentials, e.g. food and rent. Choose one next move.",
    "Review essentials, i.e. food and rent. Choose one next move.",
    'Ask "Do I need it?" before buying. Choose one next move.',
    "Ask “Do I need it?” before buying. Choose one next move.",
    "Pause... then check the plan. Choose one next move.",
    "Pause… then check the plan. Choose one next move."
  ].each_with_index do |reply, index|
    test "inline punctuation case #{index} does not add sentences" do
      @persona.response_shape["max_sentences"] = 2
      assert Mia::ResponseShapePolicy.valid?(reply, persona: @persona), reply
    end
  end

  test "dollar endings decimals and completed quoted sentences retain boundaries" do
    [
      "The quoted price is $100. Review the plan.",
      "The quoted price is $100.25. Review the plan.",
      'You said "Pause." Review the plan.',
      "Pause... Review the plan.",
      "Mrs. Mel says to pause. Review the plan."
    ].each do |reply|
      assert Mia::ResponseShapePolicy.valid?(reply, persona: @persona), reply
    end
  end
end
