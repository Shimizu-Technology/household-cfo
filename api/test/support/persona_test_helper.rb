# frozen_string_literal: true

module PersonaTestHelper
  def persona_user(role: "coach", email: nil)
    User.create!(
      clerk_id: "clerk_#{SecureRandom.hex(8)}",
      email: email || "#{SecureRandom.hex(8)}@example.com",
      role: role,
      invitation_status: "accepted"
    )
  end

  def persona_configuration(assistant_name: "Mia", coach_name: "Mrs. Mel")
    Mia::PersonaSchema.default_configuration(
      assistant_name: assistant_name,
      human_coach_name: coach_name,
      human_coach_title: "Household CFO coach"
    )
  end

  def create_persona(creator: persona_user, name: "Household CFO")
    CoachPersona.create!(
      name: name,
      description: "A coach-approved participant experience.",
      draft_config: persona_configuration,
      created_by_user: creator
    )
  end
end
