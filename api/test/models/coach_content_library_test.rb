# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CoachContentLibraryTest < ActiveSupport::TestCase
  include PersonaTestHelper

  test "approved items and published packs are immutable and do not silently upgrade" do
    coach = persona_user
    item = approved_content_item(owner: coach, content: "Use the original coach wording.")
    original_item_version = item.current_approved_version
    pack = published_content_pack(owner: coach, items: [ item ])
    original_pack_version = pack.current_published_version

    item.update!(draft_content: "Use the revised coach wording.")
    revised_item_version = item.approve!(actor: coach)

    assert_equal original_item_version, original_pack_version.item_versions.first
    assert_not_equal revised_item_version, original_pack_version.item_versions.first
    assert_raises(ActiveRecord::RecordInvalid) { original_item_version.update!(content: "mutated") }
    assert_raises(ActiveRecord::RecordInvalid) { original_pack_version.update!(name: "mutated") }

    serialized = Mia::ContentLibrarySerializer.new(policy: Mia::ContentLibraryPolicy.new(coach)).pack(pack.reload)
    assert serialized.fetch(:update_available)
    assert serialized.fetch(:item_updates_available)
    refute serialized.fetch(:has_unpublished_changes)

    pack.replace_draft_item_versions!([ revised_item_version ], actor: coach)
    assert Mia::ContentLibrarySerializer.new(policy: Mia::ContentLibraryPolicy.new(coach)).pack(pack.reload).fetch(:has_unpublished_changes)
    revised_pack_version = pack.publish!(actor: coach)
    assert_equal revised_item_version, revised_pack_version.item_versions.first
    assert_equal original_item_version, original_pack_version.reload.item_versions.first
  end

  test "coach isolation and platform authoring rules are enforced" do
    first = persona_user(email: "first-content-coach@example.com")
    second = persona_user(email: "second-content-coach@example.com")
    admin = persona_user(role: "admin")
    foreign_item = approved_content_item(owner: first)
    second_pack = CoachContentPack.create!(name: "Second coach", scope: "coach", pack_kind: "coaching_method", created_by_user: second)

    assert_raises(ArgumentError) do
      second_pack.replace_draft_item_versions!([ foreign_item.current_approved_version ], actor: second)
    end
    platform_pack = CoachContentPack.create!(name: "Platform", scope: "platform", pack_kind: "coaching_method", created_by_user: admin)
    assert_raises(ArgumentError) do
      platform_pack.replace_draft_item_versions!([ foreign_item.current_approved_version ], actor: admin)
    end
    assert_not CoachContentItem.new(title: "Platform", scope: "platform", kind: "guidance", draft_content: "Text", created_by_user: first).valid?
    assert CoachContentItem.new(title: "Platform", scope: "platform", kind: "guidance", draft_content: "Text", created_by_user: admin).valid?
  end

  test "persona publishing and rollback preserve exact pack links and manifest digests" do
    coach = persona_user
    first_item = approved_content_item(owner: coach, title: "Original")
    first_pack = published_content_pack(owner: coach, items: [ first_item ], name: "Original pack")
    persona = create_persona(creator: coach)
    persona.replace_draft_content_pack_versions!([ first_pack.current_published_version ], actor: coach)
    first_persona_version = publish_persona(persona, actor: coach)

    second_item = approved_content_item(owner: coach, title: "Later")
    second_pack = published_content_pack(owner: coach, items: [ second_item ], name: "Later pack")
    persona.replace_draft_content_pack_versions!([ second_pack.current_published_version ], actor: coach)
    second_persona_version = publish_persona(persona, actor: coach)

    assert_equal [ first_pack.current_published_version_id ], first_persona_version.content_pack_version_ids
    assert_equal [ second_pack.current_published_version_id ], second_persona_version.content_pack_version_ids
    assert_not_equal first_persona_version.content_manifest_digest, second_persona_version.content_manifest_digest
    assert_not_equal first_persona_version.publication_digest, second_persona_version.publication_digest

    restored = Mia::PersonaRollback.new(persona: persona, target_version: first_persona_version, actor: coach).call(
      expected_current_version_id: second_persona_version.id,
      expected_draft_revision: persona.reload.draft_revision
    )
    assert_equal [ first_pack.current_published_version_id ], restored.content_pack_version_ids
    assert_equal [ first_pack.current_published_version_id ], persona.reload.draft_content_pack_version_ids
  end

  test "changing exact source links invalidates preview" do
    coach = persona_user
    persona = create_persona(creator: coach)
    item = approved_content_item(owner: coach)
    pack = published_content_pack(owner: coach, items: [ item ])
    publisher = Mia::PersonaPublisher.new(persona: persona, actor: coach)
    preview = publisher.preview!(expected_draft_revision: persona.draft_revision)

    persona.replace_draft_content_pack_versions!([ pack.current_published_version ], actor: coach)

    assert_nil persona.reload.preview_digest
    refute_equal preview.fetch(:digest), publisher.compile_preview!(expected_draft_revision: persona.draft_revision).fetch(:digest)
  end

  test "assistant messages expose supplied-source provenance without raw internal ids" do
    coach = persona_user
    item = approved_content_item(owner: coach, title: "One clear move")
    pack = published_content_pack(owner: coach, items: [ item ], name: "Coach steps")
    participant = persona_user(role: "participant")
    household = Household.create!(created_by_user: participant, name: "Citation household")
    session = household.chat_sessions.create!(user: participant, title: "Ask Mia")
    message = session.chat_messages.create!(role: "assistant", content: "Choose one next move.")
    message.coach_content_citations.create!(
      coach_content_item_version: item.current_approved_version,
      coach_content_pack_version: pack.current_published_version,
      rank: 1,
      reason: "Matched: move"
    )

    citation = message.reload.as_api_json.fetch(:citations).first
    assert_equal "One clear move", citation.fetch(:title)
    assert_equal "Coach steps", citation.fetch(:pack_name)
    assert_equal 1, citation.fetch(:pack_version)
    refute citation.key?(:coach_content_item_version_id)

    message.delete
    assert_empty CoachContentCitation.where(chat_message_id: message.id)
  end
end
