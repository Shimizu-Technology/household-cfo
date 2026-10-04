require "test_helper"
require_relative "../support/savings_debt_test_support"

class SavingsOptionalDebtTest < ActiveSupport::TestCase
  include SavingsDebtTestSupport
  setup do
    travel_to Date.new(2026, 11, 1).in_time_zone("Pacific/Guam").noon
    setup_savings_context
  end
  teardown { travel_back }

  test "manual approval preserves nullable and known zero terms without budget or savings mutation" do
    with_savings_runtime do
      savings_enroll
      unknown = debt_approve(debt_stage(debt_terms(balance_cents: nil, apr_bps: nil, minimum_payment_cents: nil)))
      zero = debt_approve(debt_stage(debt_terms(label: "Paid-off high APR", balance_cents: 0, apr_bps: 2999, minimum_payment_cents: 0, status: "paid_off")))
      assert_nil unknown.terms["balance_cents"]
      assert_equal 0, zero.terms["balance_cents"]
      assert_equal [], debt_read[:avalanche_order]
      assert_equal [], debt_read[:snowball_order]
      assert_equal 1, debt_read[:unknown_balance_count]
      assert_nil debt_read[:extra_payment_cents]
      assert_nil debt_read[:payoff_date]
      assert_equal 0, SavingsEntryVersion.where(savings_enrollment: @savings_enrollment).count
      assert_equal 0, @savings_household.debts.count
      assert_equal 0, @savings_household.budget_years.count
      assert_equal 0, @savings_enrollment.reload.approval_sequence
      assert_nil savings_projection[:reported_cents]
    end
  end

  test "comparison qualifies promo multiple rate unknown and paid-off cards instead of inventing a ranking" do
    with_savings_runtime do
      savings_enroll
      high = debt_approve(debt_stage(debt_terms(label: "Higher APR", apr_bps: 2499, balance_cents: 10_000)))
      low = debt_approve(debt_stage(debt_terms(label: "Lower APR", apr_bps: 1000, balance_cents: 5000)))
      [ debt_terms(label: "Promo", apr_bps: 2000, promotional_apr_bps: 0, promotional_expires_on: "2026-10-31", post_promo_apr_bps: nil),
        debt_terms(label: "Split rates", apr_bps: 2400, rate_segments: [ { label: "Purchases", balance_cents: 10_000, apr_bps: 1999 }, { label: "Advance", balance_cents: 20_000, apr_bps: 2999 } ]),
        debt_terms(label: "Unknown balance high APR", balance_cents: nil, apr_bps: 9999), debt_terms(label: "Archived", apr_bps: 9999, status: "archived") ].each { |terms| debt_approve(debt_stage(terms)) }
      state = debt_read
      assert_equal [ high.savings_debt_card_id, low.savings_debt_card_id ], state[:avalanche_order]
      assert_equal low.savings_debt_card_id, state[:snowball_order].first
      promo = state[:cards].find { |row| row[:label] == "Promo" }
      assert promo[:promotional_expired]
      assert_includes promo[:qualifications], "promotional_terms_need_review"
      refute state[:portfolio_complete]
      assert_nil state[:savings_credit_cents]
    end
  end

  test "draft correction preserves head until approval and old reviews or older statements fail closed" do
    with_savings_runtime do
      savings_enroll
      first = debt_approve(debt_stage)
      card = first.savings_debt_card
      pending = debt_stage(debt_terms(balance_cents: 40_000), card: card)
      assert_equal 30_000, debt_read[:cards].sole[:terms]["balance_cents"]
      winner = debt_approve(debt_stage(debt_terms(balance_cents: 20_000), card: card))
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { debt_approve(pending) }
      assert_equal winner.id, card.reload.current_version_id
      assert_equal 30_000, first.reload.terms["balance_cents"]
      assert_raises(ArgumentError) { debt_stage(debt_terms(as_of_on: "2026-10-31"), card: card) }
      assert_raises(ActiveRecord::RecordNotSaved) { first.update!(terms: first.terms.merge("balance_cents" => 0)) }
    end
  end

  test "strict exact fields reject floats negatives injections impossible days and overallocated rates" do
    with_savings_runtime do
      savings_enroll
      [ { balance_cents: 1.5 }, { minimum_payment_cents: "50" }, { balance_cents: -1 }, { apr_bps: 1.25 }, { apr_bps: -1 },
        { as_of_on: "2026-02-30" }, { as_of_on: "0000-01-01" }, { as_of_on: "2026-11-02" }, { currency: "EUR" }, { reporting_known: true },
        { status: "paid_off", balance_cents: nil }, { rate_segments: [ { label: "Too much", balance_cents: 30_001, apr_bps: 100 } ] } ].each do |extra|
        assert_raises(ArgumentError) { debt_stage(debt_terms(**extra)) }
      end
      assert_equal 0, SavingsDebtDraft.count
    end
  end

  test "execution and generic audits minimize all optional card facts while replay preserves original approval" do
    with_savings_runtime do
      savings_enroll
      token = "private financial card text"
      draft = debt_stage(debt_terms(label: "Private card label"))
      first = debt_approve(draft, token: token)
      again = debt_approve(draft, token: token)
      assert_equal first.id, again.id
      execution = @savings_household.household_operation_executions.where(operation_key: "savings.debt.approve").sole
      %w[normalized_input before_snapshot predicted_after_snapshot after_snapshot].each { |key| assert_equal({}, execution.public_send(key)) }
      refute_includes execution.household_audit_event.metadata.to_json, "Private card label"
      refute_includes execution.idempotency_key, token
      assert_raises(HouseholdFinance::Operations::Runner::IdempotencyConflict) { savings_run("debt.approve", debt_approval_input(draft).merge(accepted: false), token: token) }
      @savings_cohort.update!(savings_challenge_release_hold: true)
      assert_raises(SavingsChallenge::AccessPolicy::Unavailable) { debt_approve(draft, token: token) }
    end
  end

  test "explicit liability mapping uses exact current source versions and original deletion retains approved terms" do
    with_savings_runtime do
      savings_enroll
      identity, import, = debt_source
      candidate = SavingsChallenge::Debt::SourceMapping.new(@savings_household).candidate(identity)
      assert_nil candidate.dig(:proposed_terms, :apr_bps)
      assert_equal 30_000, candidate.dig(:proposed_terms, :balance_cents)
      version = debt_approve(debt_stage(debt_terms(as_of_on: "2026-10-31"), source: debt_mapping(identity)))
      refute debt_read[:cards].sole[:source_stale]
      import.update!(source_deleted_at: Time.current)
      refute debt_read[:cards].sole[:source_stale]
      assert_equal 30_000, version.reload.terms["balance_cents"]
      assert_nil savings_projection[:reported_cents]
    end
  end

  test "approved source row correction invalidates old proof and prevents stale pending card approval" do
    with_savings_runtime do
      savings_enroll
      identity, _, row = debt_source
      source = debt_mapping(identity)
      version = debt_approve(debt_stage(debt_terms(as_of_on: "2026-10-31", apr_bps: 1999), source: source))
      draft = debt_stage(debt_terms(as_of_on: "2026-10-31", balance_cents: 31_000), card: version.savings_debt_card, source: source)
      debt_source_review(row.financial_source_event, identity: identity, amount: -11_000, type: "purchase", on: Date.new(2026, 10, 31))
      assert debt_read[:cards].sole[:source_stale]
      assert_equal [], debt_read[:avalanche_order]
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { debt_approve(draft) }
      assert_equal version.id, version.savings_debt_card.reload.current_version_id
    end
  end

  test "asset unknown mappings and fingerprint mismatches cannot be treated as cards" do
    with_savings_runtime do
      savings_enroll
      asset, = debt_source(basis: "asset")
      assert_nil SavingsChallenge::Debt::SourceMapping.new(@savings_household).candidate(asset)
      identity, = debt_source
      source = debt_mapping(identity)
      assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { debt_stage(debt_terms(as_of_on: "2026-10-31"), source: source.merge(fingerprint: "0" * 64)) }
      assert_raises(ArgumentError) { debt_stage(debt_terms, source: source) }
    end
  end

  test "a canonical liability cannot be mapped twice and an older approved statement cannot win over a newer one" do
    with_savings_runtime do
      savings_enroll
      older, = debt_source(on: Date.new(2026, 9, 30))
      debt_approve(debt_stage(debt_terms(as_of_on: "2026-09-30"), source: debt_mapping(older)))
      pending = debt_stage(debt_terms(as_of_on: "2026-09-30"), source: debt_mapping(older))
      assert_raises(ArgumentError) { debt_approve(pending) }
      newer, = debt_source(tracked: older.source_tracked_account)
      assert_nil SavingsChallenge::Debt::SourceMapping.new(@savings_household).candidate(older)
      assert_equal "2026-10-31", SavingsChallenge::Debt::SourceMapping.new(@savings_household).candidate(newer)[:statement_as_of_on]
      assert debt_read[:cards].sole[:source_stale]
    end
  end

  test "Mia reads approved qualified comparisons and missing APR is not a no-debt claim" do
    with_savings_runtime do
      savings_enroll
      debt_approve(debt_stage(debt_terms(label: "Reviewed card", apr_bps: 1999)))
      answer = SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: @savings_enrollment, message: "No minimum payment information for my credit card").call
      assert_includes answer, "Reviewed card"
      assert_includes answer, "cannot recommend an extra-payment amount"
      refute_includes answer, "You can participate without credit cards or debt"
      no_debt = SavingsChallenge::CoachAnswerer.new(household: @savings_household, user: @savings_user, enrollment: @savings_enrollment, message: "I have no debt").call
      assert_includes no_debt, "You can participate without credit cards or debt"
    end
  end
end
