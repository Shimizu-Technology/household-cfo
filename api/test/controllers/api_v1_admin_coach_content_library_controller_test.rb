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

    post "/api/v1/admin/content_items/#{item_id}/approve", headers: auth_headers(coach), as: :json
    assert_response :success
    item_version_id = response.parsed_body.dig("approved_version", "id")

    post "/api/v1/admin/content_packs", params: { pack: { name: "Guam context", description: "Coach-reviewed context", scope: "coach", pack_kind: "voice_culture", item_version_ids: [ item_version_id ] } }, headers: auth_headers(coach), as: :json
    assert_response :created
    pack_id = response.parsed_body.dig("pack", "id")

    post "/api/v1/admin/content_packs/#{pack_id}/publish", headers: auth_headers(coach), as: :json
    assert_response :success
    pack_version_id = response.parsed_body.dig("published_version", "id")

    patch "/api/v1/admin/personas/#{persona.id}/content_packs", params: { content_packs: { draft_revision: persona.draft_revision, pack_version_ids: [ pack_version_id ] } }, headers: auth_headers(coach), as: :json
    assert_response :success
    assert_equal [ pack_version_id ], response.parsed_body.dig("persona", "content_packs").pluck("id")
    assert_equal persona.draft_revision + 1, response.parsed_body.dig("persona", "draft_revision")
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
