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

  private
  def access!(key)
    CohortReleases::OperationAccess.require!(household: @savings_household, user: @savings_user, key: key, cohort: @savings_cohort)
  end
end
