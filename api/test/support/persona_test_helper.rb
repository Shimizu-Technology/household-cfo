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

  def cohort_for(creator, name:, status: "active")
    Cohort.create!(name: name, status: status, created_by_user: creator)
  end

  def publish_persona(persona, actor:)
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: actor)
    preview = publisher.preview!(expected_draft_revision: persona.reload.draft_revision)
    publisher.publish!(
      expected_preview_digest: preview.fetch(:digest),
      expected_draft_revision: persona.draft_revision,
      expected_current_version_id: persona.current_published_version_id
    )
  end


  def approved_content_item(owner:, title: "Ask one clear question", kind: "guidance", content: "Ask one clear question, then offer one practical next step.", scope: "coach")
    item = CoachContentItem.create!(
      title: title,
      scope: scope,
      kind: kind,
      draft_content: content,
      created_by_user: owner
    )
    item.approve!(actor: owner)
    item
  end

  def published_content_pack(owner:, items:, name: "Coach method", pack_kind: "coaching_method", scope: "coach")
    pack = CoachContentPack.create!(
      name: name,
      description: "Reviewed coaching content.",
      scope: scope,
      pack_kind: pack_kind,
      created_by_user: owner
    )
    pack.replace_draft_item_versions!(items.map(&:current_approved_version), actor: owner)
    pack.publish!(actor: owner)
    pack
  end
end
