# frozen_string_literal: true

require "test_helper"

class CohortExperienceEffectiveCapabilitiesResolverTest < ActiveSupport::TestCase
  test "standalone keeps the existing full experience" do
    capabilities = CohortExperience::EffectiveCapabilitiesResolver.new(cohort_membership: nil).call

    assert_equal "standalone_default", capabilities.fetch(:source)
    assert capabilities.fetch(:modules).all? { |item| item.fetch(:enabled) }
  end

  test "missing cohort configuration safely exposes only core modules" do
    admin = create_user("admin")
    participant = create_user("participant")
    cohort = Cohort.create!(name: "Safe default #{SecureRandom.hex(3)}", status: "active", created_by_user: admin)
    cohort.cohort_experience_configuration.destroy!
    cohort.reload
    membership = cohort.cohort_memberships.create!(user: participant, role: "participant")

    capabilities = CohortExperience::EffectiveCapabilitiesResolver.new(cohort_membership: membership).call

    assert_equal "safe_default", capabilities.fetch(:source)
    assert capabilities.fetch(:modules).select { |item| item.fetch(:core) }.all? { |item| item.fetch(:enabled) }
    refute capabilities.fetch(:modules).reject { |item| item.fetch(:core) }.any? { |item| item.fetch(:enabled) }
  end

  test "published cohort configuration controls only optional modules" do
    coach = create_user("coach")
    participant = create_user("participant")
    cohort = Cohort.create!(name: "Published #{SecureRandom.hex(3)}", status: "active", created_by_user: coach)
    membership = cohort.cohort_memberships.create!(user: participant, role: "participant")
    configuration = cohort.cohort_experience_configuration
    configuration.update!(
      draft_config: CohortExperience::Schema::DEFAULT_CONFIG.deep_merge("optional_modules" => { "optionality" => true }),
      last_edited_by_user: coach
    )
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)

    modules = CohortExperience::EffectiveCapabilitiesResolver.new(cohort_membership: membership).call.fetch(:modules).index_by { |item| item.fetch(:id) }

    assert modules.fetch("wealth").fetch(:enabled)
    assert modules.fetch("optionality").fetch(:enabled)
    refute modules.fetch("cfo_filter").fetch(:enabled)
  end

  test "malformed published configuration safely exposes only core modules" do
    coach = create_user("coach")
    participant = create_user("participant")
    cohort = Cohort.create!(name: "Malformed #{SecureRandom.hex(3)}", status: "active", created_by_user: coach)
    membership = cohort.cohort_memberships.create!(user: participant, role: "participant")
    configuration = cohort.cohort_experience_configuration
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    version = publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)
    version.update_column(:config, { "schema_version" => 99, "optional_modules" => { "cfo_filter" => true, "optionality" => true } })

    capabilities = CohortExperience::EffectiveCapabilitiesResolver.new(cohort_membership: membership).call

    assert_equal "safe_default", capabilities.fetch(:source)
    assert capabilities.fetch(:modules).select { |item| item.fetch(:core) }.all? { |item| item.fetch(:enabled) }
    refute capabilities.fetch(:modules).reject { |item| item.fetch(:core) }.any? { |item| item.fetch(:enabled) }
  end

  private

  def create_user(role)
    User.create!(
      clerk_id: "resolver_#{SecureRandom.hex(6)}",
      email: "resolver-#{SecureRandom.hex(6)}@example.com",
      first_name: "Riley",
      role: role,
      invitation_status: "accepted"
    )
  end
end
