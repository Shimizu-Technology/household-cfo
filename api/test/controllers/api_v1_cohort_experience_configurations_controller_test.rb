# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class ApiV1CohortExperienceConfigurationsControllerTest < ActionDispatch::IntegrationTest
  include PersonaTestHelper

  test "assigned coach can save preview and publish while participants cannot manage" do
    admin = create_user("admin")
    coach = create_user("coach")
    participant = create_user("participant")
    cohort = Cohort.create!(name: "Coach tools #{SecureRandom.hex(3)}", status: "active", created_by_user: admin)
    cohort.cohort_memberships.create!(user: coach, role: "coach")
    cohort.cohort_memberships.create!(user: participant, role: "participant")

    get endpoint(cohort), headers: auth_headers(participant)
    assert_response :forbidden

    get endpoint(cohort), headers: auth_headers(coach)
    assert_response :success
    assert_equal false, response.parsed_body.dig("experience_configuration", "draft", "optional_modules", "cfo_filter")

    patch endpoint(cohort), params: {
      experience_configuration: {
        draft_revision: 1,
        draft_config: { schema_version: 1, optional_modules: { cfo_filter: true, optionality: false } }
      }
    }, headers: auth_headers(coach), as: :json
    assert_response :success
    assert_equal 2, response.parsed_body.dig("experience_configuration", "draft_revision")

    post "#{endpoint(cohort)}/preview", params: {
      experience_configuration: { draft_revision: 2 }
    }, headers: auth_headers(coach), as: :json
    assert_response :success
    digest = response.parsed_body.dig("preview", "digest")

    post "#{endpoint(cohort)}/publish", params: {
      experience_configuration: {
        draft_revision: 2,
        preview_digest: digest,
        expected_published_version_id: nil
      }
    }, headers: auth_headers(coach), as: :json
    assert_response :success
    assert_equal true, response.parsed_body.dig("published_version", "config", "optional_modules", "cfo_filter")
  end

  test "disabled modules are omitted from workspace and denied by direct endpoints" do
    coach = create_user("coach")
    participant = create_user("participant")
    cohort = Cohort.create!(name: "Participant tools #{SecureRandom.hex(3)}", status: "active", created_by_user: coach)
    cohort.cohort_memberships.create!(user: participant, role: "participant")
    configuration = cohort.cohort_experience_configuration
    configuration.update!(
      draft_config: CohortExperience::Schema::DEFAULT_CONFIG.deep_merge("optional_modules" => { "optionality" => true }),
      last_edited_by_user: coach
    )
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)

    get "/api/v1/workspace", headers: auth_headers(participant)
    assert_response :success
    assert response.parsed_body.key?("optionality")
    refute response.parsed_body.key?("cfoFilter")
    assert_equal false, response.parsed_body.dig("workspace", "capabilities", "modules").find { |item| item.fetch("id") == "cfo_filter" }.fetch("enabled")

    get "/api/v1/cfo-filter", headers: auth_headers(participant)
    assert_response :forbidden
    assert_equal "module_disabled", response.parsed_body.fetch("code")
    assert_equal "cfo_filter", response.parsed_body.fetch("module_id")

    get "/api/v1/optionality", headers: auth_headers(participant)
    assert_response :success
  end

  test "coach cannot manage another cohort and completed cohorts are read only" do
    admin = create_user("admin")
    coach = create_user("coach")
    cohort = Cohort.create!(name: "Outside #{SecureRandom.hex(3)}", status: "completed", created_by_user: admin)

    get endpoint(cohort), headers: auth_headers(coach)
    assert_response :not_found

    get endpoint(cohort), headers: auth_headers(admin)
    assert_response :success
    patch endpoint(cohort), params: {
      experience_configuration: {
        draft_revision: 1,
        draft_config: { schema_version: 1, optional_modules: { cfo_filter: true, optionality: true } }
      }
    }, headers: auth_headers(admin), as: :json
    assert_response :unprocessable_entity
  end

  test "malformed draft configuration values return a typed validation response" do
    admin = create_user("admin")
    cohort = Cohort.create!(name: "Malformed input #{SecureRandom.hex(3)}", status: "active", created_by_user: admin)

    [ "not-an-object", [ { cfo_filter: true } ], nil ].each do |draft_config|
      patch endpoint(cohort), params: {
        experience_configuration: { draft_revision: 1, draft_config: draft_config }
      }, headers: auth_headers(admin), as: :json

      assert_response :unprocessable_entity
      assert_equal "experience_configuration_invalid", response.parsed_body.fetch("code")
    end

    patch endpoint(cohort), params: { experience_configuration: "not-an-object" }, headers: auth_headers(admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "experience_configuration_invalid", response.parsed_body.fetch("code")
  end

  test "stale draft updates and mismatched publish previews return stable conflict codes" do
    admin = create_user("admin")
    cohort = Cohort.create!(name: "Conflict codes #{SecureRandom.hex(3)}", status: "active", created_by_user: admin)

    patch endpoint(cohort), params: {
      experience_configuration: {
        draft_revision: 999,
        draft_config: CohortExperience::Schema::LEGACY_CONFIG
      }
    }, headers: auth_headers(admin), as: :json
    assert_response :conflict
    assert_equal "experience_draft_conflict", response.parsed_body.fetch("code")

    post "#{endpoint(cohort)}/preview", params: {
      experience_configuration: { draft_revision: 1 }
    }, headers: auth_headers(admin), as: :json
    assert_response :success

    post "#{endpoint(cohort)}/publish", params: {
      experience_configuration: {
        draft_revision: 1,
        preview_digest: "0" * 64,
        expected_published_version_id: nil
      }
    }, headers: auth_headers(admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "experience_preview_required", response.parsed_body.fetch("code")
  end

  test "read only lifecycle errors return a typed unprocessable response" do
    admin = create_user("admin")
    cohort = Cohort.create!(name: "Read only lifecycle #{SecureRandom.hex(3)}", status: "active", created_by_user: admin)
    post "#{endpoint(cohort)}/preview", params: {
      experience_configuration: { draft_revision: 1 }
    }, headers: auth_headers(admin), as: :json
    assert_response :success
    digest = response.parsed_body.dig("preview", "digest")
    post "#{endpoint(cohort)}/publish", params: {
      experience_configuration: {
        draft_revision: 1,
        preview_digest: digest,
        expected_published_version_id: nil
      }
    }, headers: auth_headers(admin), as: :json
    assert_response :success
    version_id = response.parsed_body.dig("published_version", "id")
    cohort.update!(status: "completed")

    post "#{endpoint(cohort)}/preview", params: {
      experience_configuration: { draft_revision: 1 }
    }, headers: auth_headers(admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "experience_configuration_read_only", response.parsed_body.fetch("code")

    post "#{endpoint(cohort)}/publish", params: {
      experience_configuration: {
        draft_revision: 1,
        preview_digest: digest,
        expected_published_version_id: version_id
      }
    }, headers: auth_headers(admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "experience_configuration_read_only", response.parsed_body.fetch("code")

    post "#{endpoint(cohort)}/versions/#{version_id}/rollback", params: {
      experience_configuration: {
        draft_revision: 1,
        expected_published_version_id: version_id
      }
    }, headers: auth_headers(admin), as: :json
    assert_response :unprocessable_entity
    assert_equal "experience_configuration_read_only", response.parsed_body.fetch("code")
  end

  test "rollback conflicts return 409 and versions stay scoped to their cohort" do
    admin = create_user("admin")
    cohort = Cohort.create!(name: "Rollback conflict #{SecureRandom.hex(3)}", status: "active", created_by_user: admin)
    other_cohort = Cohort.create!(name: "Cross cohort version #{SecureRandom.hex(3)}", status: "active", created_by_user: admin)
    version = publish_configuration(cohort.cohort_experience_configuration, admin, cfo_filter: true, optionality: false)
    other_version = publish_configuration(other_cohort.cohort_experience_configuration, admin, cfo_filter: false, optionality: true)

    post "#{version_endpoint(cohort, version)}/rollback", params: {
      experience_configuration: {
        draft_revision: cohort.cohort_experience_configuration.draft_revision,
        expected_published_version_id: 999_999
      }
    }, headers: auth_headers(admin), as: :json
    assert_response :conflict
    assert_equal "experience_rollback_conflict", response.parsed_body.fetch("code")

    get version_endpoint(cohort, other_version), headers: auth_headers(admin)
    assert_response :not_found
    assert_equal "experience_version_not_found", response.parsed_body.fetch("code")
  end

  test "workspace capabilities use only participant-role cohort membership" do
    admin = create_user("admin")
    staff = create_user("coach")
    participant_cohort = Cohort.create!(
      name: "Participant policy #{SecureRandom.hex(3)}",
      status: "active",
      starts_on: Date.new(2026, 8, 1),
      created_by_user: admin
    )
    coached_cohort = Cohort.create!(
      name: "Coach policy #{SecureRandom.hex(3)}",
      status: "active",
      starts_on: Date.new(2027, 1, 1),
      created_by_user: admin
    )
    participant_membership = participant_cohort.cohort_memberships.create!(user: staff, role: "participant")
    coached_cohort.cohort_memberships.create!(user: staff, role: "coach")
    publish_configuration(participant_cohort.cohort_experience_configuration, admin, cfo_filter: false, optionality: true)
    coach_persona = CoachPersona.create!(
      name: "Coach-only voice",
      description: "Must not leak into participant context.",
      draft_config: persona_configuration(assistant_name: "Coach Cohort Voice", coach_name: "Coach Morgan"),
      created_by_user: admin
    )
    publish_persona(coach_persona, actor: admin)
    CohortPersonaAssignment.create!(cohort: coached_cohort, coach_persona: coach_persona, assigned_by_user: admin)

    get "/api/v1/workspace", headers: auth_headers(staff)

    assert_response :success
    capabilities = response.parsed_body.dig("workspace", "capabilities")
    assert_equal participant_cohort.id, capabilities.fetch("cohort_id")
    assert_equal participant_cohort.id, response.parsed_body.dig("workspace", "cohort", "id")
    assert_equal "Mia", response.parsed_body.dig("profile", "coach", "name")
    assert_equal "published_cohort", capabilities.fetch("source")
    modules = capabilities.fetch("modules").index_by { |item| item.fetch("id") }
    refute modules.fetch("cfo_filter").fetch("enabled")
    assert modules.fetch("optionality").fetch("enabled")

    participant_membership.destroy!
    get "/api/v1/workspace", headers: auth_headers(staff)

    assert_response :success
    capabilities = response.parsed_body.dig("workspace", "capabilities")
    assert_nil capabilities.fetch("cohort_id")
    assert_equal "standalone_default", capabilities.fetch("source")
    assert capabilities.fetch("modules").all? { |item| item.fetch("enabled") }
  end

  private

  def endpoint(cohort)
    "/api/v1/admin/cohorts/#{cohort.id}/experience_configuration"
  end

  def version_endpoint(cohort, version)
    "#{endpoint(cohort)}/versions/#{version.id}"
  end

  def create_user(role)
    User.create!(
      clerk_id: "controller_experience_#{SecureRandom.hex(6)}",
      email: "controller-experience-#{SecureRandom.hex(6)}@example.com",
      first_name: "Morgan",
      role: role,
      invitation_status: "accepted"
    )
  end

  def auth_headers(user)
    { "Authorization" => "Bearer test_token_#{user.id}" }
  end

  def publish_configuration(configuration, actor, cfo_filter:, optionality:)
    configuration.update!(
      draft_config: {
        "schema_version" => 1,
        "optional_modules" => { "cfo_filter" => cfo_filter, "optionality" => optionality }
      },
      last_edited_by_user: actor
    )
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: actor)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: configuration.draft_revision,
      expected_current_version_id: configuration.current_published_version_id
    )
  end
end
