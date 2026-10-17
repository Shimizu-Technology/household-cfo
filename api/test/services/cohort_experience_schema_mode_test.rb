# frozen_string_literal: true

require "test_helper"

class CohortExperienceSchemaModeTest < ActiveSupport::TestCase
  test "mode_payload names the experience participants get" do
    assert_equal({ mode: "household_cfo", label: "Household CFO" }, CohortExperience::Schema.mode_payload(CohortExperience::Schema::DEFAULT_CONFIG))
    assert_equal({ mode: "savings_challenge", label: "90-day Savings Challenge" }, CohortExperience::Schema.mode_payload(CohortExperience::Schema::PILOT_SAVINGS_CONFIG))
    assert_equal "household_cfo", CohortExperience::Schema.mode_for(nil)
  end

  test "release_supports_challenge? is false without a release" do
    refute SavingsChallenge::AccessPolicy.release_supports_challenge?(nil)
  end
end
