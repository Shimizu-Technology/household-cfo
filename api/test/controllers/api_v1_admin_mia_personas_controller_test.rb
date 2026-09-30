# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1AdminMiaPersonasControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  test "persona studio requires staff authentication" do
    get "/api/v1/admin/personas"

    assert_response :unauthorized
    assert_equal "Missing bearer token", response.parsed_body.fetch("error")

    participant = persona_user(role: "participant")
    get "/api/v1/admin/personas", headers: auth_headers(participant)

    assert_response :forbidden
    assert_equal "Staff access required", response.parsed_body.fetch("error")
  end

  test "admin sees every persona while coach visibility is owned or assigned and assignment details stay scoped" do
    admin = persona_user(role: "admin")
    coach = persona_user(role: "coach")
    coach_cohort = cohort_for(admin, name: "Coach-visible cohort")
    outside_cohort = cohort_for(admin, name: "Outside cohort")
    coach.cohort_memberships.create!(cohort: coach_cohort, role: "coach")

    owned = persona_for(coach, assistant_name: "Owned assistant")
    assigned = persona_for(admin, assistant_name: "Assigned assistant")
    hidden = persona_for(admin, assistant_name: "Hidden assistant")
    publish_persona(assigned, actor: admin)
    CohortPersonaAssignment.create!(cohort: coach_cohort, coach_persona: assigned, assigned_by_user: admin)
    CohortPersonaAssignment.create!(cohort: outside_cohort, coach_persona: assigned, assigned_by_user: admin)

    get "/api/v1/admin/personas", headers: auth_headers(coach)

    assert_response :success
    coach_ids = response.parsed_body.fetch("personas").pluck("id")
    assert_equal [ owned.id, assigned.id ].sort, coach_ids.sort
    refute_includes coach_ids, hidden.id

    get "/api/v1/admin/personas/#{assigned.id}", headers: auth_headers(coach)

    assert_response :success
    detail = response.parsed_body.fetch("persona")
    assert_equal false, detail.dig("permissions", "edit")
    assert_equal [ coach_cohort.id ], detail.fetch("assignments").map { |item| item.dig("cohort", "id") }
    refute_includes response.body, outside_cohort.name

    get "/api/v1/admin/personas/#{hidden.id}", headers: auth_headers(coach)

    assert_response :not_found

    get "/api/v1/admin/personas", headers: auth_headers(admin)

    assert_response :success
    admin_ids = response.parsed_body.fetch("personas").pluck("id")
    assert_includes admin_ids, owned.id
    assert_includes admin_ids, assigned.id
    assert_includes admin_ids, hidden.id
  end

  test "create binds ownership to current staff and update invalidates preview with optimistic revision checking" do
    admin = persona_user(role: "admin")
    coach = persona_user(role: "coach")
    draft = persona_configuration(assistant_name: "Auntie Ava")

    post "/api/v1/admin/personas",
      params: {
        persona: {
          name: "Ignored display name",
          description: "Coach-approved assistant.",
          draft_config: draft,
          created_by_user_id: admin.id,
          archived_at: Time.current,
          current_published_version_id: 99
        }
      },
      headers: auth_headers(coach),
      as: :json

    assert_response :created
    persona = CoachPersona.find(response.parsed_body.dig("persona", "id"))
    assert_equal coach, persona.created_by_user
    assert_equal "Auntie Ava", persona.name
    assert_nil persona.archived_at
    assert_nil persona.current_published_version_id

    post "/api/v1/admin/personas/#{persona.id}/preview",
      params: { preview: { draft_revision: 1, sample_prompt: "Can I afford this?" } },
      headers: auth_headers(coach),
      as: :json

    assert_response :success
    assert response.parsed_body.dig("preview", "guardrails_applied")
    assert_match(/\A[0-9a-f]{64}\z/, persona.reload.preview_digest)

    changed_draft = persona.draft_config.deep_merge("voice" => { "energy" => "Calm, clear, and grounded." })
    patch "/api/v1/admin/personas/#{persona.id}",
      params: { persona: { draft_revision: 1, description: "Updated description.", draft_config: changed_draft } },
      headers: auth_headers(coach),
      as: :json

    assert_response :success
    persona.reload
    assert_equal 2, persona.draft_revision
    assert_nil persona.preview_digest
    assert_nil response.parsed_body.dig("persona", "preview")

    patch "/api/v1/admin/personas/#{persona.id}",
      params: { persona: { draft_revision: 1, description: "Stale write" } },
      headers: auth_headers(coach),
      as: :json

    assert_response :conflict
    assert_equal "persona_draft_conflict", response.parsed_body.fetch("code")
    assert_equal "Updated description.", persona.reload.description
  end

  test "preview publish version detail and rollback form an immutable audited lifecycle" do
    coach = persona_user(role: "coach")
    persona = persona_for(coach, assistant_name: "Versioned assistant")

    first_version = preview_and_publish_through_api(persona, coach)
    assert_equal 1, first_version.version_number
    assert_equal coach, first_version.published_by_user

    revised_draft = persona.reload.draft_config.deep_merge("voice" => { "energy" => "Warm with firm accountability." })
    patch "/api/v1/admin/personas/#{persona.id}",
      params: { persona: { draft_revision: 1, draft_config: revised_draft } },
      headers: auth_headers(coach),
      as: :json
    assert_response :success

    second_version = preview_and_publish_through_api(persona.reload, coach, expected_version_id: first_version.id)
    assert_equal 2, second_version.version_number

    get "/api/v1/admin/personas/#{persona.id}/versions/#{first_version.id}", headers: auth_headers(coach)

    assert_response :success
    assert_equal first_version.config, response.parsed_body.dig("version", "config")

    post "/api/v1/admin/personas/#{persona.id}/versions/#{first_version.id}/rollback",
      params: {
        rollback: {
          expected_published_version_id: second_version.id,
          draft_revision: persona.reload.draft_revision
        }
      },
      headers: auth_headers(coach),
      as: :json

    assert_response :success
    restored = CoachPersonaVersion.find(response.parsed_body.dig("published_version", "id"))
    assert_equal 3, restored.version_number
    assert_equal first_version.config, restored.config
    assert_equal first_version, restored.source_version
    assert_equal %w[publish publish rollback], persona.publication_events.order(:id).pluck(:event_type)

    post "/api/v1/admin/personas/#{persona.id}/versions/#{first_version.id}/rollback",
      params: {
        rollback: {
          expected_published_version_id: second_version.id,
          draft_revision: persona.reload.draft_revision
        }
      },
      headers: auth_headers(coach),
      as: :json

    assert_response :conflict
    assert_equal "persona_rollback_conflict", response.parsed_body.fetch("code")
    assert_equal 3, persona.versions.count
  end

  test "publish rejects an absent exact preview and stale published version" do
    coach = persona_user(role: "coach")
    persona = persona_for(coach, assistant_name: "Conflict assistant")

    post "/api/v1/admin/personas/#{persona.id}/publish",
      params: {
        publish: {
          draft_revision: persona.draft_revision,
          preview_digest: "0" * 64,
          expected_published_version_id: nil
        }
      },
      headers: auth_headers(coach),
      as: :json

    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors"), "Preview this exact draft before publishing"

    first = preview_and_publish_through_api(persona.reload, coach)
    post "/api/v1/admin/personas/#{persona.id}/preview",
      params: { preview: { draft_revision: persona.reload.draft_revision } },
      headers: auth_headers(coach),
      as: :json
    assert_response :success
    digest = response.parsed_body.dig("preview", "digest")

    post "/api/v1/admin/personas/#{persona.id}/publish",
      params: {
        publish: {
          draft_revision: persona.reload.draft_revision,
          preview_digest: digest,
          expected_published_version_id: first.id + 10_000
        }
      },
      headers: auth_headers(coach),
      as: :json

    assert_response :conflict
    assert_equal "persona_publish_conflict", response.parsed_body.fetch("code")
    assert_equal 1, persona.versions.count
  end

  test "archive is blocked while assigned and preserves published history after unassignment" do
    admin = persona_user(role: "admin")
    persona = persona_for(admin, assistant_name: "Archived assistant")
    published = publish_persona(persona, actor: admin)
    cohort = cohort_for(admin, name: "Archive guard cohort")
    assignment = CohortPersonaAssignment.create!(cohort: cohort, coach_persona: persona, assigned_by_user: admin)

    delete "/api/v1/admin/personas/#{persona.id}", headers: auth_headers(admin)

    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors"), "Remove every cohort assignment before archiving this persona."
    assert_nil persona.reload.archived_at

    assignment.destroy!
    delete "/api/v1/admin/personas/#{persona.id}", headers: auth_headers(admin)

    assert_response :success
    assert_equal "archived", response.parsed_body.dig("persona", "status")
    assert persona.reload.archived?
    assert_equal published, persona.current_published_version
    assert_equal 1, persona.versions.count
  end

  private

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def cohort_for(creator, name:, status: "active")
    Cohort.create!(name: name, status: status, created_by_user: creator)
  end

  def persona_for(creator, assistant_name:)
    CoachPersona.create!(
      name: assistant_name,
      description: "A coach-approved participant experience.",
      draft_config: persona_configuration(assistant_name: assistant_name, coach_name: creator.full_name),
      created_by_user: creator
    )
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

  def preview_and_publish_through_api(persona, user, expected_version_id: nil)
    post "/api/v1/admin/personas/#{persona.id}/preview",
      params: { preview: { draft_revision: persona.reload.draft_revision } },
      headers: auth_headers(user),
      as: :json
    assert_response :success
    preview_digest = response.parsed_body.dig("preview", "digest")

    post "/api/v1/admin/personas/#{persona.id}/publish",
      params: {
        publish: {
          draft_revision: persona.reload.draft_revision,
          preview_digest: preview_digest,
          expected_published_version_id: expected_version_id
        }
      },
      headers: auth_headers(user),
      as: :json
    assert_response :success
    CoachPersonaVersion.find(response.parsed_body.dig("published_version", "id"))
  end
end
