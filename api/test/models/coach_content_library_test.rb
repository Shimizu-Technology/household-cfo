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
    workspace = pack.coach_workspace

    item.update!(draft_content: "Use the revised coach wording.")
    revised_item_version = item.approve!(actor: coach, expected_draft_revision: item.draft_revision, expected_draft_digest: item.draft_digest)

    assert_equal original_item_version, original_pack_version.item_versions.first
    assert_not_equal revised_item_version, original_pack_version.item_versions.first
    assert_raises(ActiveRecord::RecordInvalid) { original_item_version.update!(content: "mutated") }
    assert_raises(ActiveRecord::RecordInvalid) { original_pack_version.update!(name: "mutated") }

    serialized = Mia::ContentLibrarySerializer.new(policy: Mia::ContentLibraryPolicy.new(coach, workspace: workspace)).pack(pack.reload)
    assert serialized.fetch(:update_available)
    assert serialized.fetch(:item_updates_available)
    refute serialized.fetch(:has_unpublished_changes)

    pack.replace_draft_item_versions!([ revised_item_version ], actor: coach)
    assert Mia::ContentLibrarySerializer.new(policy: Mia::ContentLibraryPolicy.new(coach, workspace: workspace)).pack(pack.reload).fetch(:has_unpublished_changes)
    revised_pack_version = pack.publish!(actor: coach, expected_draft_revision: pack.draft_revision, expected_draft_manifest_digest: pack.draft_manifest_digest, expected_current_version_id: pack.current_published_version_id)
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
    policy = Mia::PersonaStudioPolicy.new(coach, workspace: persona.coach_workspace)
    assert Mia::PersonaStudioSerializer.new(persona.reload, policy: policy).summary.fetch(:has_unpublished_changes)
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
    assert restored.content_manifest_valid?
  end

  test "sealed pack and persona publications reject appended rows and fail closed after manifest tampering" do
    coach = persona_user
    first_item = approved_content_item(owner: coach, title: "Sealed first")
    second_item = approved_content_item(owner: coach, title: "Sealed second")
    pack = published_content_pack(owner: coach, items: [ first_item ])
    persona = create_persona(creator: coach)
    persona.replace_draft_content_pack_versions!([ pack.current_published_version ], actor: coach)
    persona_version = publish_persona(persona, actor: coach)

    assert pack.current_published_version.sealed?
    assert persona_version.sealed?
    assert_raises(ActiveRecord::RecordInvalid) do
      pack.current_published_version.entries.create!(coach_content_item_version: second_item.current_approved_version, position: 1)
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      persona_version.content_pack_links.create!(coach_content_pack_version: pack.current_published_version, position: 1)
    end

    pack.current_published_version.update_column(:content_digest, "0" * 64)
    refute pack.current_published_version.reload.manifest_valid?
    refute persona_version.reload.content_manifest_valid?
    assert_empty Mia::ApprovedContentRetriever.new(persona: Mia::RuntimePersona.new(persona_version), query: "sealed first").call

    pack.current_published_version.update_column(
      :content_digest,
      CoachContentPackVersion.content_digest_for(pack.current_published_version)
    )
    first_item.current_approved_version.update_column(:content, "Tampered approved wording")
    refute first_item.current_approved_version.reload.content_digest_valid?
    refute pack.current_published_version.reload.manifest_valid?
    refute persona_version.reload.content_manifest_valid?
    assert_empty Mia::ApprovedContentRetriever.new(persona: Mia::RuntimePersona.new(persona_version), query: "tampered wording").call
    assert_raises(Mia::PersonaPublisher::PublicationError) do
      Mia::PersonaPublisher.new(persona: persona.reload, actor: coach).compile_preview!(expected_draft_revision: persona.draft_revision)
    end
    policy = Mia::PersonaStudioPolicy.new(coach, workspace: persona.coach_workspace)
    assert Mia::PersonaStudioSerializer.new(persona, policy: policy).summary.fetch(:has_unpublished_changes)
  end

  test "manifests include immutable record identities even when approved text is identical" do
    admin = persona_user(role: "admin")
    coach = persona_user
    platform_item = approved_content_item(owner: admin, title: "Same words", content: "Identical approved text.", scope: "platform")
    coach_item = approved_content_item(owner: coach, title: "Same words", content: "Identical approved text.")
    assert_equal platform_item.current_approved_version.content_digest, coach_item.current_approved_version.content_digest

    platform_pack = published_content_pack(owner: admin, items: [ platform_item ], name: "Same pack", scope: "platform")
    coach_pack = published_content_pack(owner: coach, items: [ coach_item ], name: "Same pack")
    refute_equal platform_pack.current_published_version.content_digest, coach_pack.current_published_version.content_digest

    first_manifest = CoachPersonaVersion.content_manifest_digest_for([ platform_pack.current_published_version ])
    second_manifest = CoachPersonaVersion.content_manifest_digest_for([ coach_pack.current_published_version ])
    refute_equal first_manifest, second_manifest
  end

  test "pack publication fails atomically when a selected approved item was tampered" do
    coach = persona_user
    original_item = approved_content_item(owner: coach, title: "Original valid item")
    pack = published_content_pack(owner: coach, items: [ original_item ])
    original_version = pack.current_published_version
    selected_item = approved_content_item(owner: coach, title: "Selected item", content: "Approved exact wording")
    pack.replace_draft_item_versions!([ selected_item.current_approved_version ], actor: coach)
    expected_revision = pack.draft_revision
    expected_manifest = pack.draft_manifest_digest
    selected_item.current_approved_version.update_column(:content, "Tampered wording")

    assert_no_difference -> { pack.versions.count } do
      error = assert_raises(CoachContentPack::PublicationIntegrityError) do
        pack.publish!(
          actor: coach,
          expected_draft_revision: expected_revision,
          expected_draft_manifest_digest: expected_manifest,
          expected_current_version_id: original_version.id
        )
      end
      assert_includes error.message, "integrity validation"
    end

    assert_equal original_version.id, pack.reload.current_published_version_id
    assert_equal expected_revision, pack.draft_revision
    assert_equal [ selected_item.current_approved_version_id ], pack.draft_item_version_ids
  end

  test "pack version sealing rejects an invalid approved item before setting the seal" do
    coach = persona_user
    pack = CoachContentPack.create!(name: "Construction integrity", scope: "coach", pack_kind: "coaching_method", created_by_user: coach)
    item = approved_content_item(owner: coach, title: "Construction item", content: "Approved wording")
    version = pack.versions.create!(
      version_number: 1,
      name: pack.name,
      description: "",
      scope: pack.scope,
      pack_kind: pack.pack_kind,
      content_digest: "0" * 64,
      published_by_user: coach
    )
    version.entries.create!(coach_content_item_version: item.current_approved_version, position: 0)
    item.current_approved_version.update_column(:content, "Tampered wording")

    error = assert_raises(ArgumentError) { version.seal! }

    assert_includes error.message, "cannot seal invalid approved item versions"
    assert_nil version.reload.sealed_at
    assert_equal "0" * 64, version.content_digest
    assert_nil pack.reload.current_published_version_id
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

  test "content library serialization uses preloaded associations with bounded queries" do
    coach = persona_user
    items = 3.times.map do |index|
      approved_content_item(owner: coach, title: "Serializer item #{index}", content: "Approved serializer content #{index}.")
    end
    packs = items.map.with_index do |item, index|
      published_content_pack(owner: coach, items: [ item ], name: "Serializer pack #{index}")
    end
    workspace = CoachWorkspaces::Resolver.new(user: coach).call
    policy = Mia::ContentLibraryPolicy.new(coach, workspace: workspace)

    loaded_items = policy.visible_items.where(id: items.map(&:id))
      .includes(:current_approved_version, :versions).to_a
    loaded_packs = policy.visible_packs.where(id: packs.map(&:id)).includes(
      current_published_version: { entries: { coach_content_item_version: :source_provenance } },
      versions: { entries: { coach_content_item_version: :source_provenance } },
      draft_entries: { coach_content_item_version: [ :source_provenance, { coach_content_item: :current_approved_version } ] }
    ).to_a
    count_content_queries = lambda do |&block|
      count = 0
      callback = lambda do |*, payload|
        next if payload[:name] == "SCHEMA" || payload[:cached]
        next unless payload[:sql].match?(/SELECT.+coach_content_/m)

        count += 1
      end
      ActiveRecord::Base.connection.uncached do
        ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      end
      count
    end

    item_serializer = Mia::ContentLibrarySerializer.new(policy: policy)
    item_queries = count_content_queries.call { @serialized_items = loaded_items.map { |item| item_serializer.item(item) } }
    pack_serializer = Mia::ContentLibrarySerializer.new(policy: policy)
    pack_queries = count_content_queries.call { @serialized_packs = loaded_packs.map { |pack| pack_serializer.pack(pack) } }

    assert_equal 1, item_queries
    assert_equal 1, pack_queries
    assert_equal items.map(&:id).sort, @serialized_items.pluck(:id).sort
    assert_equal packs.map(&:id).sort, @serialized_packs.pluck(:id).sort
    assert @serialized_packs.all? { |pack| pack.fetch(:draft_manifest_digest).present? }
    assert @serialized_packs.all? { |pack| pack.dig(:current_published_version, :items)&.one? }
  end

  test "citation item must belong to the cited pack snapshot" do
    coach = persona_user
    included = approved_content_item(owner: coach, title: "Included citation")
    excluded = approved_content_item(owner: coach, title: "Excluded citation")
    pack = published_content_pack(owner: coach, items: [ included ])
    participant = persona_user(role: "participant")
    household = Household.create!(created_by_user: participant, name: "Citation integrity")
    message = household.chat_sessions.create!(user: participant, title: "Ask Mia").chat_messages.create!(role: "assistant", content: "Context")

    citation = message.coach_content_citations.new(
      coach_content_item_version: excluded.current_approved_version,
      coach_content_pack_version: pack.current_published_version,
      rank: 1,
      reason: "Context supplied"
    )
    refute citation.valid?
    assert_includes citation.errors[:coach_content_item_version], "must belong to the cited content pack version"
  end
end
