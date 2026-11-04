require "test_helper"
require_relative "../support/savings_daily_test_support"

class CohortReleasesOperationAccessTest < ActiveSupport::TestCase
  include SavingsDailyTestSupport
  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "older sealed release keeps foundation authority without acquiring newly deployed tools" do
    original = CohortReleases::ToolContracts.method(:version_for_experience)
    CohortReleases::ToolContracts.define_singleton_method(:version_for_experience) { |_config| 3 }
    with_savings_runtime { savings_enroll; savings_plan }
    assert_equal 3, @savings_release.tool_registry_version
    assert_equal 53, @savings_release.tool_registry_snapshot.fetch("operations").length
    assert access!("savings.entry.stage")
    assert access!("source_review.account.link")
    %w[baseline.approve savings.daily.check_in.save savings.checkpoint.stage savings.evidence.attach privacy.consent.set reminder.preference.set].each do |key|
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { access!(key) }
    end
    assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { SavingsChallenge::Daily::ReadPolicy.call!(@savings_enrollment, user: @savings_user) }
    assert_equal 50_000, savings_projection[:target_cents]
  ensure
    CohortReleases::ToolContracts.define_singleton_method(:version_for_experience, original) if original
  end

  test "current release authorizes exact registered keys and rechecks hold and removed membership" do
    with_savings_runtime { savings_enroll }
    assert access!("savings.evidence.attach")
    assert access!("baseline.approve")
    @savings_cohort.update!(savings_challenge_release_hold: true)
    assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { access!("baseline.approve") }
    @savings_cohort.update!(savings_challenge_release_hold: false)
    @savings_membership.destroy!
    assert_raises(SavingsChallenge::AccessPolicy::Unavailable) do
      CohortReleases::OperationAccess.require!(household: @savings_household, user: @savings_user, key: "baseline.approve")
    end
  end

  test "a removed pilot cannot regain default tools through an unreleased ordinary cohort" do
    with_savings_runtime { savings_enroll }
    @savings_membership.destroy!
    ordinary = Cohort.create!(name: "Unreleased ordinary program", status: "enrolling", created_by_user: @savings_owner)
    CohortMembership.create!(cohort: ordinary, user: @savings_user, role: "participant")
    assert_raises(SavingsChallenge::AccessPolicy::Unavailable) do
      CohortReleases::OperationAccess.require!(household: @savings_household, user: @savings_user, key: "baseline.approve", cohort: ordinary)
    end
  end

  [ :schema, :digest ].each do |corruption|
    test "invalid published prelaunch #{corruption} cannot authorize statement operations" do
      @savings_cohort.update!(savings_challenge_enabled: false)
      cohort = Cohort.create!(name: "Invalid prelaunch #{corruption}", status: "enrolling", created_by_user: @savings_owner)
      membership = cohort.cohort_memberships.create!(user: @savings_user, role: "participant")
      configuration = cohort.cohort_experience_configuration
      configuration.update!(draft_config: CohortExperience::Schema::DEFAULT_CONFIG.deep_merge("optional_modules" => { "statements" => false }))
      publisher = CohortExperience::Publisher.new(configuration: configuration, actor: @savings_owner)
      digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
      version = publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)
      if corruption == :schema
        version.update_column(:config, { "schema_version" => 99 })
      else
        version.update_column(:config_digest, "0" * 64)
      end
      refute cohort.cohort_releases.exists?
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) do
        CohortReleases::OperationAccess.require!(household: @savings_household, user: @savings_user, membership: membership, key: "source_review.account.link")
      end
    end
  end

  private
  def access!(key)
    CohortReleases::OperationAccess.require!(household: @savings_household, user: @savings_user, key: key, cohort: @savings_cohort)
  end
end
