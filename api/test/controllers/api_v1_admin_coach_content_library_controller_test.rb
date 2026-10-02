# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminCoachContentLibraryControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  test "participants are denied and coaches cannot read or mutate another coach draft" do
    owner = persona_user(email: "content-owner@example.com")
    other = persona_user(email: "content-other@example.com")
    participant = persona_user(role: "participant")
    item = approved_content_item(owner: owner, title: "Private owner guidance")

    get "/api/v1/admin/content_items", headers: auth_headers(participant)
    assert_response :forbidden

    get "/api/v1/admin/content_items", headers: auth_headers(other)
    assert_response :success
    refute_includes response.parsed_body.fetch("items").pluck("id"), item.id

    patch "/api/v1/admin/content_items/#{item.id}", params: { item: { draft_revision: 1, title: "Stolen", kind: "guidance", draft_content: "No" } }, headers: auth_headers(other), as: :json
    assert_response :not_found
    assert_equal "Private owner guidance", item.reload.title
  end

  test "manual item pack and persona link flow pins exact approved versions" do
    coach = persona_user
    persona = create_persona(creator: coach)

    post "/api/v1/admin/content_items", params: { item: { title: "Guam family context", scope: "coach", kind: "culture", draft_content: "Mention extended-family obligations only when the participant raises them." } }, headers: auth_headers(coach), as: :json
    assert_response :created
    item_id = response.parsed_body.dig("item", "id")
    item_revision = response.parsed_body.dig("item", "draft_revision")
    item_digest = response.parsed_body.dig("item", "draft_digest")

    post "/api/v1/admin/content_items/#{item_id}/approve", params: { item: { draft_revision: item_revision, draft_digest: item_digest } }, headers: auth_headers(coach), as: :json
    assert_response :success
    item_version_id = response.parsed_body.dig("approved_version", "id")

    post "/api/v1/admin/content_packs", params: { pack: { name: "Guam context", description: "Coach-reviewed context", scope: "coach", pack_kind: "voice_culture", item_version_ids: [ item_version_id ] } }, headers: auth_headers(coach), as: :json
    assert_response :created
    pack_id = response.parsed_body.dig("pack", "id")
    pack_revision = response.parsed_body.dig("pack", "draft_revision")
    pack_manifest = response.parsed_body.dig("pack", "draft_manifest_digest")

    post "/api/v1/admin/content_packs/#{pack_id}/publish", params: { pack: { draft_revision: pack_revision, draft_manifest_digest: pack_manifest, expected_published_version_id: nil } }, headers: auth_headers(coach), as: :json
    assert_response :success
    pack_version_id = response.parsed_body.dig("published_version", "id")

    patch "/api/v1/admin/personas/#{persona.id}/content_packs", params: { content_packs: { draft_revision: persona.draft_revision, pack_version_ids: [ pack_version_id ] } }, headers: auth_headers(coach), as: :json
    assert_response :success
    assert_equal [ pack_version_id ], response.parsed_body.dig("persona", "content_packs").pluck("id")
    assert_equal persona.draft_revision + 1, response.parsed_body.dig("persona", "draft_revision")
  end

  test "direct content item APIs cannot mint or convert governed phrases" do
    coach = persona_user
    admin = persona_user(role: "admin")

    assert_no_difference -> { CoachContentItem.count } do
      post "/api/v1/admin/content_items", params: {
        item: { title: "Manual phrase", scope: "coach", kind: "phrase", draft_content: "Håfa adai" }
      }, headers: auth_headers(coach), as: :json
    end
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("error"), "approved coaching workspace phrase review"

    assert_no_difference -> { CoachContentItem.count } do
      post "/api/v1/admin/content_items", params: {
        item: { title: "Platform phrase", scope: "platform", kind: "phrase", draft_content: "Håfa adai" }
      }, headers: auth_headers(admin), as: :json
    end
    assert_response :unprocessable_entity

    item = CoachContentItem.create!(
      title: "Ordinary guidance", scope: "coach", kind: "guidance",
      draft_content: "Choose one practical next step.", created_by_user: coach
    )
    patch "/api/v1/admin/content_items/#{item.id}", params: {
      item: { draft_revision: item.draft_revision, kind: "phrase" }
    }, headers: auth_headers(coach), as: :json
    assert_response :unprocessable_entity
    assert_equal "guidance", item.reload.kind
  end

  test "approval and publication reject stale tabs and mismatched canonical drafts" do
    coach = persona_user
    item = CoachContentItem.create!(title: "CAS item", scope: "coach", kind: "guidance", draft_content: "Original", created_by_user: coach)
    stale_revision = item.draft_revision
    stale_digest = item.draft_digest
    item.update!(draft_content: "Changed elsewhere")

    post "/api/v1/admin/content_items/#{item.id}/approve", params: { item: { draft_revision: stale_revision, draft_digest: stale_digest } }, headers: auth_headers(coach), as: :json
    assert_response :conflict
    assert_nil item.reload.current_approved_version

    post "/api/v1/admin/content_items/#{item.id}/approve", params: { item: { draft_revision: item.draft_revision, draft_digest: "0" * 64 } }, headers: auth_headers(coach), as: :json
    assert_response :conflict
    assert_nil item.reload.current_approved_version

    approved = approved_content_item(owner: coach, title: "CAS pack item")
    pack = CoachContentPack.create!(name: "CAS pack", scope: "coach", pack_kind: "coaching_method", created_by_user: coach)
    pack.replace_draft_item_versions!([ approved.current_approved_version ], actor: coach)
    stale_pack_revision = pack.draft_revision
    stale_pack_manifest = pack.draft_manifest_digest
    pack.update!(description: "Changed elsewhere")

    post "/api/v1/admin/content_packs/#{pack.id}/publish", params: { pack: { draft_revision: stale_pack_revision, draft_manifest_digest: stale_pack_manifest, expected_published_version_id: nil } }, headers: auth_headers(coach), as: :json
    assert_response :conflict
    assert_nil pack.reload.current_published_version

    current_version = pack.publish!(
      actor: coach,
      expected_draft_revision: pack.draft_revision,
      expected_draft_manifest_digest: pack.draft_manifest_digest,
      expected_current_version_id: nil
    )
    pack.update!(description: "A new draft after publication")

    post "/api/v1/admin/content_packs/#{pack.id}/publish", params: { pack: { draft_revision: pack.draft_revision, draft_manifest_digest: pack.draft_manifest_digest, expected_published_version_id: nil } }, headers: auth_headers(coach), as: :json
    assert_response :conflict
    assert_equal current_version, pack.reload.current_published_version
  end

  test "coach cannot attach another coach pack version" do
    owner = persona_user
    other = persona_user
    item = approved_content_item(owner: owner)
    pack = published_content_pack(owner: owner, items: [ item ])
    persona = create_persona(creator: other)

    patch "/api/v1/admin/personas/#{persona.id}/content_packs", params: { content_packs: { draft_revision: persona.draft_revision, pack_version_ids: [ pack.current_published_version_id ] } }, headers: auth_headers(other), as: :json

    assert_response :unprocessable_entity
    assert_equal "persona_content_pack_unavailable", response.parsed_body.fetch("code")
    assert_empty persona.reload.draft_content_pack_versions
  end

  test "tampered selected content returns a recoverable publication error without promotion" do
    coach = persona_user
    original_item = approved_content_item(owner: coach, title: "Published original")
    pack = published_content_pack(owner: coach, items: [ original_item ])
    original_version = pack.current_published_version
    selected_item = approved_content_item(owner: coach, title: "Tampered selection", content: "Approved wording")
    pack.replace_draft_item_versions!([ selected_item.current_approved_version ], actor: coach)
    revision = pack.draft_revision
    manifest = pack.draft_manifest_digest
    selected_item.current_approved_version.update_column(:content, "Changed outside the approval lifecycle")

    assert_no_difference -> { pack.versions.count } do
      post "/api/v1/admin/content_packs/#{pack.id}/publish", params: {
        pack: {
          draft_revision: revision,
          draft_manifest_digest: manifest,
          expected_published_version_id: original_version.id
        }
      }, headers: auth_headers(coach), as: :json
    end

    assert_response :unprocessable_entity
    assert_equal "content_pack_invalid", response.parsed_body.fetch("code")
    assert_includes response.parsed_body.fetch("error"), "integrity validation"
    assert_equal original_version.id, pack.reload.current_published_version_id
  end

  test "administrator cannot cross-link one coach pack to another coach persona" do
    admin = persona_user(role: "admin")
    pack_owner = persona_user(email: "pack-owner@example.com")
    persona_owner = persona_user(email: "persona-owner@example.com")
    item = approved_content_item(owner: pack_owner)
    pack = published_content_pack(owner: pack_owner, items: [ item ])
    persona = create_persona(creator: persona_owner)

    patch "/api/v1/admin/personas/#{persona.id}/content_packs", params: { content_packs: { draft_revision: persona.draft_revision, pack_version_ids: [ pack.current_published_version_id ] } }, headers: auth_headers(admin), as: :json

    assert_response :unprocessable_entity
    assert_equal "Content packs from another coach cannot be attached", response.parsed_body.fetch("error")
    assert_empty persona.reload.draft_content_pack_versions
  end

  test "persona pack selection rescues only the dedicated domain error" do
    coach = persona_user
    persona = create_persona(creator: coach)

    domain_error = assert_raises(CoachPersona::ContentPackSelectionError) do
      persona.replace_draft_content_pack_versions!(13.times.map { |index| CoachContentPackVersion.new(id: index + 1) }, actor: coach)
    end
    assert_kind_of ArgumentError, domain_error

    original = CoachPersona.instance_method(:replace_draft_content_pack_versions!)
    CoachPersona.define_method(:replace_draft_content_pack_versions!) do |*, **|
      raise ArgumentError, "unexpected programming error"
    end

    assert_raises(ArgumentError) do
      patch "/api/v1/admin/personas/#{persona.id}/content_packs",
        params: { content_packs: { draft_revision: persona.draft_revision, pack_version_ids: [] } },
        headers: auth_headers(coach),
        as: :json
    end
  ensure
    CoachPersona.define_method(:replace_draft_content_pack_versions!, original) if original
  end

  test "invalid pack item selection does not leave a partial pack" do
    coach = persona_user
    other = persona_user
    foreign_item = approved_content_item(owner: other)

    assert_no_difference -> { CoachContentPack.count } do
      post "/api/v1/admin/content_packs", params: { pack: { name: "Invalid mixed pack", scope: "coach", pack_kind: "coaching_method", item_version_ids: [ foreign_item.current_approved_version_id ] } }, headers: auth_headers(coach), as: :json
    end

    assert_response :unprocessable_entity
  end

  private

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end
end
