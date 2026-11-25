require "test_helper"
require Rails.root.join("lib/scorecard/runner")

# Talun's latest statements, approved on the scorecard path, offer their exact
# closing balances; approving them sets My Money and the readiness numbers.
class StatementBalanceTalunTest < ActionDispatch::IntegrationTest
  PATHS = %w[checking-2026-11.pdf checking-2026-12.pdf savings-2026-12.pdf card-2026-12.pdf bog-2026-11-phone-1.png bog-2026-11-phone-2.png bog-2026-11-phone-3.png].freeze

  test "approved Talun statements offer their closing balances and set balances only when she approves" do
    manifest = JSON.parse(Scorecard::Runner::TALUN.join("manifest.json").read)
    closing = ->(path) { manifest.fetch("documents").find { |doc| doc.fetch("path") == path }.dig("printed_totals_cents", "closing_balance_cents") }
    checked = false
    Scorecard::Runner.new(document_paths: PATHS, correct_proposals: false, after_review: lambda { |household, user|
      # What she typed at setup in November: a checking balance as of Nov 1 and a Visa card with no date.
      checking = household.accounts.create!(label: "Everyday checking ····4410", account_type: "checking", balance_cents: 5_000_00, balance_as_of_on: Date.new(2026, 11, 1), source_type: "setup")
      visa = household.debts.create!(label: "Mainland Visa", debt_type: "credit_card", balance_cents: 4_000_00, minimum_payment_cents: 90_00)
      visa.update_columns(created_at: Time.zone.local(2026, 11, 15), updated_at: Time.zone.local(2026, 11, 15))
      headers = { "Authorization" => "Bearer test_token_#{user.id}" }

      get "/api/v1/statement_balances", headers: headers
      assert_response :success
      offers = response.parsed_body.fetch("offers").index_by { |offer| offer.fetch("statement_label") }
      # Bank of Guam's latest month is phone screenshots, which print no balance: no offer, never an older one.
      assert_equal [ "Checking ····4410", "Mainland Visa ····6074", "Talun Savings ····8642" ], offers.keys.sort
      assert_equal closing.call("checking-2026-12.pdf"), offers.dig("Checking ····4410", "balance_cents")
      assert_equal closing.call("savings-2026-12.pdf"), offers.dig("Talun Savings ····8642", "balance_cents")
      assert_equal closing.call("card-2026-12.pdf"), offers.dig("Mainland Visa ····6074", "balance_cents")
      assert offers.values.all? { |offer| offer.fetch("as_of_on") == "2026-12-31" }
      # Listing changed nothing.
      assert_equal 5_000_00, checking.reload.balance_cents
      assert_equal 4_000_00, visa.reload.balance_cents

      # Same last four digits: her checking is the suggested account.
      assert_equal checking.id, offers.dig("Checking ····4410", "target", "id")
      # The card name differs, so she chooses it.
      assert_nil offers.dig("Mainland Visa ····6074", "target")
      assert_equal [ visa.id ], offers.dig("Mainland Visa ····6074", "choices").map { |row| row.fetch("id") }
      assert offers.dig("Talun Savings ····8642", "can_add_new")

      apply = lambda do |offer, kind, target, key|
        post "/api/v1/statement_balances/#{offer.fetch('tracked_account_id')}/apply", params: { kind: kind, target: target, offer_key: offer.fetch("key") },
          headers: headers.merge("Idempotency-Key" => key), as: :json
      end
      returned = -> { response.parsed_body.fetch("offers").index_by { |offer| offer.fetch("statement_label") } }
      apply.call(offers.fetch("Checking ····4410"), "account", checking.id.to_s, "talun-checking")
      assert_response :success
      # Each approval returns the current offers; their keys reflect the new balances.
      apply.call(returned.call.fetch("Talun Savings ····8642"), "account", "new", "talun-savings")
      assert_response :success
      offers = offers.merge(returned.call.slice("Mainland Visa ····6074"))
      # Her card changed in another tab after the offer was shown: nothing is overwritten.
      visa.update!(balance_cents: 4_100_00)
      visa.update_columns(updated_at: Time.zone.local(2026, 12, 20))
      apply.call(offers.fetch("Mainland Visa ····6074"), "debt", visa.id.to_s, "talun-visa-stale")
      assert_response :conflict
      assert_equal "stale_review", response.parsed_body["code"]
      assert_equal 4_100_00, visa.reload.balance_cents
      get "/api/v1/statement_balances", headers: headers
      fresh = response.parsed_body.fetch("offers").find { |offer| offer.fetch("statement_label") == "Mainland Visa ····6074" }
      assert_equal 4_100_00, fresh.fetch("choices").sole.fetch("balance_cents")
      apply.call(fresh, "debt", visa.id.to_s, "talun-visa")
      assert_response :success
      assert_empty response.parsed_body.fetch("offers")

      checking.reload
      assert_equal [ closing.call("checking-2026-12.pdf"), true, Date.new(2026, 12, 31), "document_import" ],
        [ checking.balance_cents, checking.balance_known?, checking.balance_as_of_on, checking.source_type ]
      savings = household.accounts.find_by!(label: "Talun Savings ····8642")
      assert_equal [ "savings", closing.call("savings-2026-12.pdf"), Date.new(2026, 12, 31) ], [ savings.account_type, savings.balance_cents, savings.balance_as_of_on ]
      assert_equal closing.call("card-2026-12.pdf"), visa.reload.balance_cents
      assert_equal 90_00, visa.minimum_payment_cents
      assert_equal "2026-12-31", visa.source_metadata.dig("statement_balance", "period_end_on")
      audit = household.household_audit_events.where(event_type: "household_operation.executed").order(:id).last(3).map { |event| event.metadata.fetch("operation_key") }
      assert_equal %w[account.statement_balance.apply account.statement_balance.apply debt.statement_balance.apply], audit

      # Readiness reads the approved balances through the existing paths.
      snapshot = HouseholdFinance::SnapshotBuilder.new(household.reload).call
      assert snapshot.fetch(:liquid_assets_known)
      assert_equal closing.call("checking-2026-12.pdf") + closing.call("savings-2026-12.pdf"), snapshot.fetch(:liquid_assets_cents)
      assert_equal closing.call("card-2026-12.pdf"), snapshot.fetch(:total_debt_cents)

      # Replaying the same request changes nothing more; a reused offer key is stale.
      apply.call(offers.fetch("Checking ····4410"), "account", checking.id.to_s, "talun-checking")
      assert_response :success
      apply.call(offers.fetch("Checking ····4410"), "account", checking.id.to_s, "talun-checking-again")
      assert_response :conflict
      assert_equal closing.call("checking-2026-12.pdf"), checking.reload.balance_cents

      # A manual edit after the statement wins until a newer statement arrives.
      HouseholdFinance::Operations::Runner.new(household, user: user).run(operation_key: "account.record.update", input: { account_id: checking.id, balance: "7900.00" }, idempotency_key: "manual-after-statement")
      assert_empty HouseholdFinance::StatementBalanceOffers.new(household.reload).call
      assert_equal 7_900_00, checking.reload.balance_cents
      checked = true
    }).call
    assert checked
  end
end

class StatementBalanceRulesTest < ActionDispatch::IntegrationTest
  test "a manual balance edit supersedes an unapplied savings statement offer" do
    checked = false
    Scorecard::Runner.new(document_paths: %w[savings-2026-12.pdf], correct_proposals: false, after_review: lambda { |household, user|
      savings = household.accounts.create!(label: "Talun Savings ····8642", account_type: "savings", balance_cents: 7_000_00,
        balance_as_of_on: Date.new(2026, 11, 1), source_type: "setup")
      offers = -> { HouseholdFinance::StatementBalanceOffers.new(household.reload).call }
      assert_equal savings.id, offers.call.sole.dig(:target, :id)

      HouseholdFinance::Operations::Runner.new(household, user: user).run(operation_key: "account.record.update",
        input: { account_id: savings.id, balance: "7900.00" }, idempotency_key: "manual-before-statement-approval")
      assert_empty offers.call
      assert_equal 7_900_00, savings.reload.balance_cents
      checked = true
    }).call
    assert checked
  end

  test "never offers a statement older than the saved balance, and cards only when debts are tracked one by one" do
    checked = false
    Scorecard::Runner.new(document_paths: %w[savings-2026-12.pdf card-2026-12.pdf], correct_proposals: false, after_review: lambda { |household, _user|
      offers = -> { HouseholdFinance::StatementBalanceOffers.new(household.reload).call.index_by { |offer| offer.fetch(:kind) } }
      # An unknown balance is offered, never treated as $0.
      unknown = household.accounts.create!(label: "Savings ····8642", account_type: "savings", balance_known: false, balance_cents: 0)
      assert_equal unknown.id, offers.call.dig("account", :target, :id)
      assert_nil offers.call.dig("account", :target, :balance_cents)
      tracked_id = offers.call.dig("account", :tracked_account_id)

      # A balance she saved as of the statement day, or later, keeps it.
      unknown.update!(balance_known: true, balance_cents: 7_500_00, balance_as_of_on: Date.new(2026, 12, 31))
      assert_nil offers.call["account"]
      assert_equal 7_500_00, unknown.reload.balance_cents
      unknown.update!(balance_as_of_on: Date.new(2027, 1, 5))
      assert_nil offers.call["account"]
      # So does a balance that came from a newer statement, even with no date.
      unknown.update!(balance_as_of_on: nil, source_metadata: { "statement_balance" => { "tracked_account_id" => tracked_id, "period_end_on" => "2027-01-31" } })
      assert_nil offers.call["account"]
      # The same balance as the statement needs no offer.
      unknown.update!(balance_cents: 7_400_00, source_metadata: {})
      assert_nil offers.call["account"]
      unknown.update!(balance_cents: 7_000_00, balance_as_of_on: Date.new(2026, 11, 15))
      assert_equal 7_400_00, offers.call.dig("account", :balance_cents)

      # A card edited by hand after an earlier statement shows no statement date for its current balance.
      card_tracked = offers.call.dig("debt", :tracked_account_id)
      card = household.debts.create!(label: "Mainland Visa", debt_type: "credit_card", balance_cents: 3_500_00, minimum_payment_cents: 0,
        source_type: "document_import", source_metadata: { "statement_balance" => { "tracked_account_id" => card_tracked, "period_end_on" => "2026-11-30", "closing_balance_cents" => 4_390_37 } })
      card.update_columns(updated_at: Time.zone.local(2026, 12, 10))
      assert_equal [ card.id, nil ], offers.call.dig("debt", :target).values_at(:id, :balance_as_of_on)
      card.destroy!

      # Summary debt tracking has no per-card balance to update.
      assert offers.call["debt"]
      household.household_profile.update!(debt_tracking_mode: "summary")
      assert_nil offers.call["debt"]
      assert_equal 7_000_00, unknown.reload.balance_cents

      # An account she archived keeps its statement: no other account or new one is offered.
      unknown.update!(source_metadata: { "statement_balance" => { "tracked_account_id" => tracked_id, "period_end_on" => "2026-11-30" } })
      assert_equal unknown.id, offers.call.dig("account", :target, :id)
      unknown.update!(active: false, archived_at: Time.current)
      assert_nil offers.call["account"]
      checked = true
    }).call
    assert checked
  end
end

class StatementBalanceKindsTest < ActionDispatch::IntegrationTest
  test "loans, retirement and investment accounts can be chosen; a new record is the kind she picks; an undated balance typed after the statement keeps winning" do
    checked = false
    Scorecard::Runner.new(document_paths: %w[savings-2026-12.pdf card-2026-12.pdf], correct_proposals: false, after_review: lambda { |household, user|
      offers = -> { HouseholdFinance::StatementBalanceOffers.new(household.reload).call.index_by { |offer| offer.fetch(:kind) } }
      runner = HouseholdFinance::Operations::Runner.new(household, user: user)
      november = Time.zone.local(2026, 11, 20)

      # Every debt kind is a choice for a liability statement, not only cards.
      loan = household.debts.create!(label: "Island Auto Loan", debt_type: "auto_loan", balance_cents: 9_000_00, minimum_payment_cents: 300_00)
      loan.update_columns(created_at: november, updated_at: november)
      assert_includes offers.call.dig("debt", :choices).map { |row| row[:id] }, loan.id
      assert_equal HouseholdFinance::StatementBalanceOffers::DEBT_TYPES, offers.call.dig("debt", :new_type_options)
      # "Mainland Visa" names a card; nothing else is assumed.
      assert_equal "credit_card", offers.call.dig("debt", :new_account_type)

      # Retirement and investment accounts are choices for an asset statement.
      retirement = household.accounts.create!(label: "Fidelity 401(k)", account_type: "retirement", balance_cents: 85_000_00, balance_as_of_on: Date.new(2026, 11, 1))
      brokerage = household.accounts.create!(label: "Brokerage", account_type: "investment", balance_cents: 12_000_00, balance_as_of_on: Date.new(2026, 11, 1))
      assert_equal [ retirement.id, brokerage.id ].sort, (offers.call.dig("account", :choices).map { |row| row[:id] } & [ retirement.id, brokerage.id ]).sort

      # A new record is saved as the kind she picks.
      offer = offers.call.fetch("debt")
      runner.run(operation_key: "debt.statement_balance.apply", input: { tracked_account_id: offer[:tracked_account_id], offer_key: offer[:key], new_debt: true, new_type: "mortgage" }, idempotency_key: "new-mortgage")
      assert_equal "mortgage", household.debts.find_by!(label: offer[:statement_label]).debt_type
      offer = offers.call.fetch("account")
      error = assert_raises(ArgumentError) do
        runner.run(operation_key: "account.statement_balance.apply", input: { tracked_account_id: offer[:tracked_account_id], offer_key: offer[:key], new_account: true, new_type: "property" }, idempotency_key: "new-property")
      end
      assert_equal "Choose what kind of account this is", error.message
      # Without her choice, nothing is guessed for a name that says nothing.
      unnamed = offer.merge(new_account_type: nil)
      assert_raises(ArgumentError) { HouseholdFinance::StatementBalanceOffers.new_record_type(unnamed, nil) }
      assert_equal "investment", HouseholdFinance::StatementBalanceOffers.new_record_type(unnamed, "investment")
      named = ->(label, kind) { HouseholdFinance::StatementBalanceOffers.new(household).send(:named_type, SourceTrackedAccount.new(label: label), kind) }
      assert_equal [ "retirement", "investment", nil, "auto_loan", "mortgage", nil ],
        [ named.call("Fidelity 401(k) ····2211", "account"), named.call("Island Brokerage ····5521", "account"), named.call("Bank account ····9056", "account"),
          named.call("Island Auto Loan ····7710", "debt"), named.call("Home Mortgage ····1200", "debt"), named.call("Island Finance ····3301", "debt") ]
      checked = true
    }).call
    assert checked
  end

  test "an undated card balance typed after the statement ends is never replaced by it; a rename does not count" do
    checked = false
    Scorecard::Runner.new(document_paths: %w[card-2026-12.pdf], correct_proposals: false, after_review: lambda { |household, user|
      offers = -> { HouseholdFinance::StatementBalanceOffers.new(household.reload).call }
      visa = household.debts.create!(label: "Mainland Visa ····6074", debt_type: "credit_card", balance_cents: 4_000_00, minimum_payment_cents: 90_00)
      # Typed today (Jan 1, 2027), after the Dec 31 statement: hers stands.
      assert_empty offers.call
      # Typed Nov 20, before the statement ended: the statement is newer.
      visa.update_columns(created_at: Time.zone.local(2026, 11, 20), updated_at: Time.zone.local(2026, 11, 20))
      assert_equal visa.id, offers.call.sole.dig(:target, :id)
      # Renaming it today changes no balance, so the statement is still newer.
      HouseholdFinance::Operations::Runner.new(household, user: user).run(operation_key: "debt.record.update", input: { debt_id: visa.id, label: "Visa ····6074" }, idempotency_key: "rename")
      assert_equal visa.id, offers.call.sole.dig(:target, :id)
      # A new balance typed today wins again.
      HouseholdFinance::Operations::Runner.new(household, user: user).run(operation_key: "debt.record.update", input: { debt_id: visa.id, balance: "4200" }, idempotency_key: "retype")
      assert_empty offers.call
      checked = true
    }).call
    assert checked
  end
end
