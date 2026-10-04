require "test_helper"

class HouseholdFinanceSavingsProjectionTest < ActiveSupport::TestCase
  Projection = HouseholdFinance::SavingsProjection
  DAY = Date.new(2026, 11, 1)

  test "only approved current heads affect reported savings and pending corrections preserve their approved head" do
    approved = contribution(10_000)
    draft = approved.merge(version_id: "version-draft", approval_state: "draft", current_head: false, signed_cents: 50_000)
    result = project([ draft, approved ])

    assert_equal 10_000, result[:reported_cents]
    assert_equal 0, result[:evidence_supported_cents]
    assert_equal 1, result[:pending_entry_count]
    assert_equal [ approved[:version_id] ], result[:included_version_ids]
    assert_equal false, result[:achieved]
  end

  test "drafts alone leave progress unknown instead of manufacturing zero or achievement" do
    result = project([ contribution(50_000).merge(approval_state: "draft") ], reporting_known: false)
    assert_equal 1, result[:pending_entry_count]
    %i[reported_cents evidence_supported_cents contribution_cents withdrawal_cents achieved progress_basis_points].each do |key|
      assert_nil result[key]
    end
  end

  test "contributions minus reserve withdrawals remain signed" do
    result = project([ contribution(20_000), withdrawal(7_500, id: "b") ])
    assert_equal 12_500, result[:reported_cents]
    assert_equal 20_000, result[:contribution_cents]
    assert_equal 7_500, result[:withdrawal_cents]
    assert_equal 2_500, result[:progress_basis_points]

    negative = project([ contribution(10_000), withdrawal(15_000, id: "b") ])
    assert_equal(-5_000, negative[:reported_cents])
    assert_equal 0, negative[:evidence_supported_cents]
    assert_equal 0, negative[:progress_basis_points]
    assert_equal false, negative[:achieved]
  end

  test "preexisting borrowed cash advance and existing internal money cannot create new progress" do
    entries = Projection::EXCLUDED_FUNDING_SOURCES.each_with_index.map do |source, index|
      contribution(50_000, id: "excluded-#{index}", supported: 50_000).merge(funding_source: source)
    end
    result = project(entries, zero_attested: true)
    assert_equal 0, result[:reported_cents]
    assert_equal 0, result[:evidence_supported_cents]
    assert_equal 4, result[:excluded_entry_count]
    assert_equal 0, result[:included_entry_count]
    assert_equal false, result[:achieved]
    assert_invalid("empty_known_ledger_requires_zero_attestation", entries)
  end

  test "new earned income gifts bonuses and a reviewed new reservation are eligible" do
    entries = Projection::ELIGIBLE_FUNDING_SOURCES.each_with_index.map do |source, index|
      contribution(1_000, id: "eligible-#{index}").merge(funding_source: source)
    end
    assert_equal 4_000, project(entries)[:reported_cents]
  end

  test "bank movement spending reduction unused budget refund and debt payment are not projector entries" do
    %w[bank_movement spending_reduction unused_budget refund debt_payment].each do |source|
      assert_invalid("invalid_funding_source", [ contribution(10_000).merge(funding_source: source) ])
    end
    assert_invalid("contribution_must_be_nonnegative", [ contribution(-100).merge(funding_source: "existing_internal_money") ])
  end

  test "exact target boundary and above target preserve amounts without rounding achievement" do
    [ [ 49_999, false, 9_999 ], [ 50_000, true, 10_000 ], [ 50_001, true, 10_000 ], [ 60_000, true, 10_000 ] ].each do |amount, achieved, basis_points|
      result = project([ contribution(amount) ])
      assert_equal amount, result[:reported_cents]
      assert_equal achieved, result[:achieved]
      assert_equal basis_points, result[:progress_basis_points]
    end
  end

  test "target not set keeps useful signed amounts without percentage or achievement" do
    result = project([ contribution(1_234) ], target_cents: nil)
    assert_equal 1_234, result[:reported_cents]
    assert_nil result[:target_cents]
    assert_nil result[:progress_basis_points]
    assert_nil result[:achieved]
    assert_invalid("target_must_be_positive_integer_or_nil", [ contribution(100) ], target_cents: 0)
  end

  test "empty ledger unknown differs from explicitly attested zero and net zero entries" do
    unknown = project([], reporting_known: false)
    assert_equal false, unknown[:reporting_known]
    assert_nil unknown[:reported_cents]
    assert_invalid("empty_known_ledger_requires_zero_attestation", [])

    attested = project([], zero_attested: true)
    assert_equal true, attested[:reporting_known]
    assert_equal true, attested[:zero_attested]
    assert_equal 0, attested[:reported_cents]
    assert_equal 0, attested[:evidence_supported_cents]
    assert_equal false, attested[:achieved]
    assert_invalid("unknown_cannot_attest_zero", [], reporting_known: false, zero_attested: true)
    assert_invalid("zero_attestation_conflicts_with_net", [ contribution(100) ], zero_attested: true)

    net_zero = project([ contribution(100, supported: 100), withdrawal(100, id: "b") ])
    assert_equal 0, net_zero[:reported_cents]
    assert_equal 0, net_zero[:evidence_supported_cents]
  end

  test "mixed evidence FIFO example treats support as a subset" do
    result = project([ contribution(20_000, supported: 20_000), contribution(10_000, id: "b"), withdrawal(15_000, id: "c") ])
    assert_equal 15_000, result[:reported_cents]
    assert_equal 5_000, result[:evidence_supported_cents]
  end

  test "partially supported lots consume supported cents first" do
    result = project([ contribution(10_000, supported: 5_000), withdrawal(2_500, id: "b") ])
    assert_equal 7_500, result[:reported_cents]
    assert_equal 2_500, result[:evidence_supported_cents]
  end

  test "withdrawal before contribution carries forward and consumes future support first" do
    result = project([ withdrawal(15_000), contribution(20_000, id: "b", supported: 20_000), contribution(10_000, id: "c") ])
    assert_equal 15_000, result[:reported_cents]
    assert_equal 5_000, result[:evidence_supported_cents]

    partial = project([ withdrawal(2_500), contribution(10_000, id: "b", supported: 5_000) ])
    assert_equal 7_500, partial[:reported_cents]
    assert_equal 2_500, partial[:evidence_supported_cents]

    negative = project([ withdrawal(15_000), contribution(10_000, id: "b", supported: 10_000) ])
    assert_equal(-5_000, negative[:reported_cents])
    assert_equal 0, negative[:evidence_supported_cents]
  end

  test "excluded funding cannot cover withdrawal carry or create supported lots" do
    entries = [ withdrawal(50), contribution(100, id: "b", supported: 100).merge(funding_source: "borrowed"), contribution(100, id: "c", supported: 75) ]
    result = project(entries)
    assert_equal 50, result[:reported_cents]
    assert_equal 25, result[:evidence_supported_cents]
    assert_equal 1, result[:excluded_entry_count]
  end

  test "current head corrections replay later withdrawals instead of retaining old lot allocations" do
    contribution_head = contribution(100, supported: 50)
    reserve_withdrawal = withdrawal(25, id: "b")
    original = project([ contribution_head, reserve_withdrawal ])
    assert_equal 75, original[:reported_cents]
    assert_equal 25, original[:evidence_supported_cents]

    corrected = contribution_head.merge(version_id: "version-corrected", signed_cents: 40, evidence_supported_cents: 40)
    changed = project([ corrected, reserve_withdrawal ])
    assert_equal 15, changed[:reported_cents]
    assert_equal 15, changed[:evidence_supported_cents]

    withdrawn_zero = reserve_withdrawal.merge(version_id: "version-withdrawal-corrected", signed_cents: 0)
    without_withdrawal = project([ corrected, withdrawn_zero ])
    assert_equal 40, without_withdrawal[:reported_cents]
    assert_equal 40, without_withdrawal[:evidence_supported_cents]
  end

  test "effective dates then stable logical identities determine lot order independent of input ordering" do
    entries = [ contribution(20_000, id: "b", supported: 20_000), contribution(10_000, id: "a"), withdrawal(15_000, id: "c") ]
    expected = project(entries)
    assert_equal 15_000, expected[:reported_cents]
    assert_equal 15_000, expected[:evidence_supported_cents]
    entries.permutation.each { |permutation| assert_equal expected, project(permutation) }

    # A later identity does not override an earlier effective date.
    earlier_supported = entries[0].merge(effective_on: DAY - 1)
    assert_equal 5_000, project([ earlier_supported, *entries.drop(1) ])[:evidence_supported_cents]
  end

  test "cutoff is inclusive reproducible and excludes future money and drafts" do
    entries = [ contribution(20_000, supported: 20_000), withdrawal(7_500, id: "b", day: DAY + 1), contribution(10_000, id: "c", day: DAY + 2) ]
    at_first = project(entries, cutoff_on: DAY)
    assert_equal 20_000, at_first[:reported_cents]
    assert_equal 20_000, at_first[:evidence_supported_cents]
    assert_equal 12_500, project(entries, cutoff_on: DAY + 1)[:reported_cents]
    assert_equal 22_500, project(entries, cutoff_on: DAY + 2)[:reported_cents]
    assert_equal at_first, project(entries.reverse, cutoff_on: DAY.iso8601)
    assert_invalid("empty_known_ledger_requires_zero_attestation", entries, cutoff_on: DAY - 2)
  end

  test "correction replaces one approved head and evidence promotion or removal changes support only" do
    original = contribution(10_000, supported: 4_000)
    corrected = original.merge(version_id: "version-corrected", signed_cents: 9_000, evidence_supported_cents: 4_500)
    promoted = corrected.merge(version_id: "version-promoted", evidence_supported_cents: 9_000)
    removed = promoted.merge(version_id: "version-unlinked", evidence_supported_cents: 0)

    assert_equal 10_000, project([ original ])[:reported_cents]
    [ corrected, promoted, removed ].each { |head| assert_equal 9_000, project([ head ])[:reported_cents] }
    assert_equal 4_500, project([ corrected ])[:evidence_supported_cents]
    assert_equal 9_000, project([ promoted ])[:evidence_supported_cents]
    assert_equal 0, project([ removed ])[:evidence_supported_cents]
    assert_invalid("duplicate_approved_logical_head", [ original, corrected ])
    assert_invalid("approved_version_is_not_current_head", [ original.merge(current_head: false), corrected ])
    assert_equal 10_000, project([ original ])[:reported_cents], "caller-selected historic head remains replayable"
  end

  test "duplicates invalid approved heads and malformed inputs fail closed even beyond cutoff" do
    valid = contribution(100)
    assert_invalid("duplicate_version_id", [ valid, valid ])
    assert_invalid("duplicate_version_id", [ valid, valid.merge(logical_entry_id: "other") ])
    assert_invalid("duplicate_approved_logical_head", [ valid, valid.merge(version_id: "different") ])
    assert_invalid("approved_version_is_not_current_head", [ valid.merge(current_head: false, effective_on: DAY + 1) ])
    {
      logical_entry_id: [ "", " a", "contains space", 123, nil ],
      version_id: [ "", nil ],
      approval_state: [ "pending", "Approved", nil ],
      current_head: [ nil, "true", 1 ],
      signed_cents: [ 100.0, "100", BigDecimal("100"), nil ],
      currency: [ "EUR", "usd", nil ],
      funding_source: [ "unknown", nil ],
      evidence_supported_cents: [ -1, 101, 1.5, "1", nil ],
      effective_on: [ "2026-02-30", "2026-11-1", "2026-11-01T00:00:00Z", Time.utc(2026, 11, 1), nil ]
    }.each do |key, values|
      values.each { |value| assert_raises(Projection::InvalidInput) { project([ valid.merge(key => value) ]) } }
    end
    assert_invalid("entry_keys_must_match_contract", [ valid.except(:currency) ])
    assert_invalid("entry_keys_must_match_contract", [ valid.merge("currency" => "USD") ])
    assert_invalid("entry_keys_must_match_contract", [ valid.merge(123 => "extra") ])
    assert_invalid("entry_keys_must_match_contract", [ nil ])
    assert_invalid("entries_must_be_array", nil)
    assert_invalid("withdrawal_must_be_nonpositive", [ valid.merge(funding_source: "withdrawal") ])
    assert_invalid("withdrawal_cannot_add_support", [ withdrawal(100).merge(evidence_supported_cents: 1) ])
    [ -100, 100.0, "100", false ].each do |target|
      assert_invalid("target_must_be_positive_integer_or_nil", [ valid ], target_cents: target)
    end
    assert_invalid("reporting_known_must_be_boolean", [ valid ], reporting_known: "true")
    assert_invalid("zero_attested_must_be_boolean", [ valid ], zero_attested: nil)
    assert_invalid("invalid_calendar_date", [ valid ], cutoff_on: "2026-02-30")
  end

  test "zero corrected heads do not create money and cannot retain evidence" do
    result = project([ contribution(0) ])
    assert_equal 0, result[:reported_cents]
    assert_equal 0, result[:evidence_supported_cents]
    assert_invalid("support_exceeds_contribution", [ contribution(0, supported: 1) ])
  end

  test "results are immutable JSON-compatible exact integers without mutating caller data" do
    input = [ contribution(50_001, supported: 49_999), withdrawal(1, id: "b") ]
    before = Marshal.load(Marshal.dump(input))
    instance = Projection.new(entries: input, cutoff_on: DAY, target_cents: 50_000, reporting_known: true)
    first = instance.call
    assert_equal first, instance.call
    assert_equal before, input
    assert first.frozen?
    assert first[:included_version_ids].frozen?
    assert first[:included_version_ids].all?(&:frozen?)
    assert_equal 50_000, JSON.parse(JSON.generate(first)).fetch("reported_cents")
    assert_equal 49_998, first[:evidence_supported_cents]
    assert first.values.none? { |value| value.is_a?(Float) || value.is_a?(Rational) }
  end

  test "exhaustive small-cent event sequences match an independent physical-token FIFO oracle" do
    possibilities = [ [ 1, 0 ], [ 1, 1 ], [ 2, 0 ], [ 2, 1 ], [ 2, 2 ], [ -1, 0 ], [ -2, 0 ] ]
    (1..4).each do |length|
      possibilities.repeated_permutation(length) do |sequence|
        entries = sequence.each_with_index.map do |(amount, supported), index|
          amount.negative? ? withdrawal(-amount, id: "entry-#{index}") : contribution(amount, id: "entry-#{index}", supported: supported)
        end
        result = project(entries, target_cents: 3)
        net, supported = token_oracle(sequence)
        assert_equal net, result[:reported_cents]
        assert_equal supported, result[:evidence_supported_cents]
        assert_operator result[:evidence_supported_cents], :<=, [ net, 0 ].max
        assert_equal net >= 3, result[:achieved]
        assert_equal ([ [ net, 0 ].max, 3 ].min * 10_000).div(3), result[:progress_basis_points]
        assert_equal result, project(entries.reverse, target_cents: 3)
      end
    end
  end

  private

  def contribution(amount, id: "a", day: DAY, supported: 0)
    {
      logical_entry_id: id, version_id: "version-#{id}", approval_state: "approved", current_head: true,
      effective_on: day, signed_cents: amount, currency: "USD", funding_source: "new_money_reserved", evidence_supported_cents: supported
    }
  end

  def withdrawal(amount, id: "a", day: DAY)
    contribution(-amount, id: id, day: day).merge(funding_source: "withdrawal")
  end

  def project(entries, **options)
    Projection.new(entries: entries, cutoff_on: DAY, target_cents: 50_000, reporting_known: true, **options).call
  end

  def assert_invalid(code, entries, **options)
    error = assert_raises(Projection::InvalidInput) { project(entries, **options) }
    assert_equal code, error.code
  end

  # Deliberately independent of production lot arithmetic: every cent is a token.
  def token_oracle(sequence)
    tokens = []
    owed = 0
    sequence.each do |amount, support|
      if amount.positive?
        new_tokens = [ true ] * support + [ false ] * (amount - support)
        owed.times { new_tokens.empty? ? nil : new_tokens.shift }
        owed = [ owed - amount, 0 ].max
        tokens.concat(new_tokens)
      else
        (-amount).times { tokens.empty? ? owed += 1 : tokens.shift }
      end
    end
    [ sequence.sum(&:first), tokens.count(true) ]
  end
end
