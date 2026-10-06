require "test_helper"

class SavingsEntryVersionTest < ActiveSupport::TestCase
  test "same-day numeric entry identities preserve creation order across decimal boundaries" do
    [ 9, 99, 999, 9_223_372_036_854_775_805 ].each do |first_id|
      entries = [
        projection_entry(first_id, 20_000).merge(evidence_supported_cents: 20_000),
        projection_entry(first_id + 1, 10_000),
        projection_entry(first_id + 2, -15_000)
      ]
      expected = HouseholdFinance::SavingsProjection.new(entries: entries, cutoff_on: "2026-11-01", reporting_known: true).call
      assert_equal 15_000, expected.fetch(:reported_cents)
      assert_equal 5_000, expected.fetch(:evidence_supported_cents), "numeric boundary #{first_id} must not reverse FIFO lots"
      assert_equal entries.pluck(:version_id), expected.fetch(:included_version_ids)
      entries.permutation.each do |ordering|
        assert_equal expected, HouseholdFinance::SavingsProjection.new(entries: ordering, cutoff_on: "2026-11-01", reporting_known: true).call
      end
    end
  end

  test "logical identity is unchanged by a new approved version while version identity remains distinct" do
    first = projection_entry(99, 20_000)
    corrected = projection_entry(99, 19_000, version_id: 201)
    assert_equal first.fetch(:logical_entry_id), corrected.fetch(:logical_entry_id)
    refute_equal first.fetch(:version_id), corrected.fetch(:version_id)
    assert_equal "version-201", corrected.fetch(:version_id)
  end

  private

  def projection_entry(entry_id, amount, version_id: entry_id)
    SavingsEntryVersion.new(id: version_id, savings_entry_id: entry_id, effective_on: "2026-11-01",
      signed_cents: amount, currency: "USD", funding_source: amount.negative? ? "withdrawal" : "new_money_reserved", evidence_supported_cents: 0).projection_input
  end
end
