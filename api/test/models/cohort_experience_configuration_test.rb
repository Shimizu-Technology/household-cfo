# frozen_string_literal: true

require "test_helper"

class CohortExperienceConfigurationTest < ActiveSupport::TestCase
  test "draft changes invalidate preview and published versions are immutable" do
    coach = create_user(role: "coach")
    configuration = create_configuration(coach)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
    digest = publisher.preview!(expected_draft_revision: 1)
    version = publisher.publish!(
      expected_preview_digest: digest,
      expected_draft_revision: 1,
      expected_current_version_id: nil
    )

    assert_equal version, configuration.reload.current_published_version
    assert_no_difference("configuration.draft_revision") do
      configuration.update!(last_edited_by_user: coach)
    end
    configuration.update!(
      draft_config: configuration.draft_config.deep_merge("optional_modules" => { "cfo_filter" => true }),
      last_edited_by_user: coach
    )
    assert_equal 2, configuration.draft_revision
    assert_nil configuration.preview_digest
    refute version.update(config: CohortExperience::Schema::LEGACY_CONFIG)
    assert_includes version.errors[:base], "published experience versions are immutable"
    assert_raises(ActiveRecord::DeleteRestrictionError) { version.destroy! }
  end

  test "schema rejects unknown modules and non boolean values" do
    coach = create_user(role: "coach")
    configuration = create_configuration(coach)
    configuration.draft_config = {
      schema_version: 1,
      optional_modules: { cfo_filter: true, optionality: "yes", secret_tool: true }
    }

    refute configuration.valid?
    assert configuration.errors[:draft_config].any? { |message| message.include?("unsupported module") }
    assert configuration.errors[:draft_config].any? { |message| message.include?("optionality") }
  end

  test "rollback creates a new immutable version and preserves provenance" do
    coach = create_user(role: "coach")
    configuration = create_configuration(coach)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
    first_digest = publisher.preview!(expected_draft_revision: 1)
    first = publisher.publish!(expected_preview_digest: first_digest, expected_draft_revision: 1, expected_current_version_id: nil)
    configuration.update!(
      draft_config: CohortExperience::Schema::LEGACY_CONFIG,
      last_edited_by_user: coach
    )
    second_digest = publisher.preview!(expected_draft_revision: 2)
    second = publisher.publish!(expected_preview_digest: second_digest, expected_draft_revision: 2, expected_current_version_id: first.id)

    restored = CohortExperience::Rollback.new(configuration: configuration, target_version: first, actor: coach).call(
      expected_current_version_id: second.id,
      expected_draft_revision: 2
    )

    assert_equal 3, restored.version_number
    assert_equal first, restored.source_version
    assert_equal first.config, restored.config
    assert_equal restored, configuration.reload.current_published_version
    assert_equal "rollback", configuration.publication_events.order(:id).last.event_type
  end

  private

  def create_user(role:)
    User.create!(
      clerk_id: "experience_#{SecureRandom.hex(6)}",
      email: "experience-#{SecureRandom.hex(6)}@example.com",
      first_name: "Casey",
      role: role,
      invitation_status: "accepted"
    )
  end

  def create_configuration(coach)
    cohort = Cohort.create!(name: "Experience #{SecureRandom.hex(4)}", status: "active", created_by_user: coach)
    cohort.cohort_experience_configuration
  end
end
