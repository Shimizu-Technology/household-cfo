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
  end

  test "does not impose custom shape rules on the global fallback persona" do
    global_persona = PersonaStub.new(nil, @persona.response_shape)

    assert Mia::ResponseShapePolicy.valid?("One sentence.", persona: global_persona)
  end
end
