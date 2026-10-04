# frozen_string_literal: true

require "test_helper"

class CohortExperienceSchemaTest < ActiveSupport::TestCase
  test "schema one defaults normalization and digests retain their historical meaning" do
    assert_equal 1, schema::DEFAULT_CONFIG.fetch("schema_version")
    assert_equal "3be07a7dd471984a8af537e0f8deef30bce2ea17b1454e750aa1eeb792d48105", schema.digest(schema::DEFAULT_CONFIG)
    assert_equal "74e76d9fa8b89e1b72b33eebb24c05cdc0c0b3bd09555f2132c655ba757a7078", schema.digest(schema::LEGACY_CONFIG)
    assert_equal schema::DEFAULT_CONFIG, schema.normalize(schema::DEFAULT_CONFIG)
    assert_empty schema.errors(schema::DEFAULT_CONFIG)
    assert_empty schema.errors(schema::LEGACY_CONFIG)
    assert_raises(FrozenError) { schema::DEFAULT_CONFIG.fetch("optional_modules")["cfo_filter"] = true }
    capabilities = payload(schema::DEFAULT_CONFIG)
    assert_equal 1, capabilities.fetch(:schema_version)
    refute capabilities.key?(:experience_mode)
  end

  test "schema two preserves an explicit savings or household experience mode" do
    %w[savings_challenge household_cfo].each do |mode|
      config = schema::SAVINGS_CONFIG.merge("experience_mode" => mode)
      assert_empty schema.errors(config)
      assert_equal config, schema.normalize(config)
      assert_equal mode, payload(config).fetch(:experience_mode)
      assert_equal 2, payload(config).fetch(:schema_version)
    end
    refute_equal schema.digest(schema::DEFAULT_CONFIG), schema.digest(schema::SAVINGS_CONFIG)
    refute_equal schema.digest(schema::SAVINGS_CONFIG), schema.digest(schema::SAVINGS_CONFIG.merge("experience_mode" => "household_cfo"))
  end

  test "new configuration does not implicitly upgrade or silently accept an invalid mode" do
    invalid = [
      schema::SAVINGS_CONFIG.except("experience_mode"),
      schema::SAVINGS_CONFIG.merge("experience_mode" => "unknown"),
      schema::SAVINGS_CONFIG.merge("experience_mode" => nil),
      schema::SAVINGS_CONFIG.merge("schema_version" => 99),
      schema::DEFAULT_CONFIG.merge("experience_mode" => "savings_challenge"),
      schema::SAVINGS_CONFIG.merge("optional_modules" => { "cfo_filter" => false, "optionality" => false, "unknown" => true }),
      schema::SAVINGS_CONFIG.merge("optional_modules" => { "cfo_filter" => "true", "optionality" => false })
    ]
    invalid.each { |config| assert schema.errors(config).any?, config.inspect }
  end

  test "published savings configuration is immutable and can roll back to schema one" do
    owner = User.create!(clerk_id: "schema-owner", email: "schema-owner@example.com", role: "coach", invitation_status: "accepted")
    cohort = Cohort.create!(name: "Schema compatibility", status: "active", created_by_user: owner)
    configuration = cohort.cohort_experience_configuration
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: owner)
    first = publish(configuration, publisher)
    original_config = first.config.deep_dup
    configuration.update!(draft_config: schema::SAVINGS_CONFIG, last_edited_by_user: owner)
    savings = publish(configuration, publisher)
    assert_equal "savings_challenge", savings.config.fetch("experience_mode")
    refute savings.update(config: schema::DEFAULT_CONFIG)
    restored = CohortExperience::Rollback.new(configuration: configuration, target_version: first, actor: owner).call(
      expected_current_version_id: savings.id, expected_draft_revision: configuration.draft_revision
    )
    assert_equal first, restored.source_version
    assert_equal original_config, restored.config
    assert_equal original_config, first.reload.config
    assert_equal schema::SAVINGS_CONFIG, savings.reload.config
  end

  private

  def schema = CohortExperience::Schema

  def payload(config)
    CohortExperience::EffectiveCapabilitiesResolver.payload_for(
      config: config, source: "test", cohort_membership: nil, version: nil
    )
  end

  def publish(configuration, publisher)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision,
      expected_current_version_id: configuration.current_published_version_id)
  end
end
