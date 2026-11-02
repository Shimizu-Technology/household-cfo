# frozen_string_literal: true

require_relative "persona_test_helper"

# Synthetic, audience-attested fixture built from the read-only Guam definition.
# Publishing uses the ordinary local test evidence helper, never production data.
module MelPersonaTestHelper
  include PersonaTestHelper

  def published_mel_program_for(user)
    source = Mia::Persona.find(Mia::Persona::DEFAULT_ID).data
    coach = persona_user
    config = persona_configuration
    config["voice"].merge!(
      "tone_traits" => %w[warm direct candid practical concise],
      "energy" => "Warm and encouraging.",
      "language_style" => [ "Use plain language.", "Prefer conversational language.", "Keep the next step concrete." ]
    )
    config["coaching"].merge!(
      "philosophy" => source.fetch("transformation_promise"),
      "method" => source.fetch("coaching_method").fetch("instructions").first(4).join(" "),
      "principles" => source.fetch("coaching_method").fetch("instructions"),
      "do" => [ source.fetch("voice").fetch("instructions").last, "Validate the choice or feeling, then coach one next move." ],
      "do_not" => source.fetch("do_not").reject { |instruction| instruction.match?(/Chamorro|\bpar\b|accent|island/i) }
    )
    config["culture"]["locale_label"] = "Guam"
    config["culture"]["context"] = "Only the individually approved phrase artifacts authorize exact wording; use their contexts and cautions."
    config["culture"]["references"] = source.fetch("culture_pack").fetch("local_references")
    contexts = { "hafa_adai" => [ "greeting" ], "chelu" => [ "general" ], "lanya" => [ "verified_milestone" ],
      "umbee_gachong" => [ "repeated_pattern" ], "biba" => [ "verified_milestone" ] }
    config["response_shape"].merge!(source.fetch("response_shape").slice("min_sentences", "max_sentences", "plain_text_only", "validate_before_coaching", "next_move_required"))
    config["phrases"] = source.fetch("phrase_library").map do |key, phrase|
      persona_phrase_artifact({ "text" => phrase.fetch("phrase"), "meaning" => phrase.fetch("use"),
        "allowed_contexts" => contexts.fetch(key), "prohibited_contexts" => %w[emotional_support crisis],
        "frequency" => phrase.fetch("frequency"),
        "caution" => [ phrase["caution"], "Never in hardship, embarrassment or shame; use sparingly, never as decoration." ].compact.join(" ") }, source_user_id: coach.id)
    end
    config["curriculum"]["examples"] = [
      { "participant" => source.fetch("demo_prompts").fetch("screenshot_spending"),
        "assistant" => source.fetch("fallbacks").fetch("spending").sub(/\ALanya /, "") },
      { "participant" => source.fetch("demo_prompts").fetch("safe_to_spend"),
        "assistant" => source.fetch("fallbacks").fetch("spending_check") }
    ]
    # Exact wording from Mel's meeting notes, supplementing the built-in chelu
    # artifact through the same synthetic audience approval path.
    config["phrases"] << persona_phrase_artifact({
      "text" => "Chelu, pump the brakes on that one",
      "meaning" => "Pause a discretionary purchase kindly before it weakens the household plan.",
      "allowed_contexts" => [ "general" ], "prohibited_contexts" => %w[emotional_support crisis],
      "frequency" => "sparing", "caution" => "Only for discretionary wants, never routine reviews, hardship or shame."
    }, source_user_id: coach.id)
    config["coaching"]["do"] << "Use the short spending examples for warm, direct accountability; at most one approved phrase when its context fits."
    config["coaching"]["do"] << "For a discretionary purchase that needs to wait, use the approved pump-the-brakes phrase once after acknowledging the want; follow it with a dignified next move."
    persona = create_persona(creator: coach, config: config)
    version = publish_persona(persona, actor: coach)
    cohort = cohort_for(coach, name: "Mrs. Mel synthetic review program")
    membership = cohort.cohort_memberships.create!(user: user, role: "participant")
    [ membership, version ]
  end
end
