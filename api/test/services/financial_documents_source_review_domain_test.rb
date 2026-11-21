require "test_helper"
require "benchmark"

class FinancialDocumentsSourceReviewDomainTest < ActiveSupport::TestCase
  OPS = HouseholdFinance::Operations::SourceReview

  setup do
    @user = User.create!(clerk_id: "source-review-#{SecureRandom.hex(8)}", email: "source-review-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = Household.create!(created_by_user: @user, name: "Synthetic source review")
    @household.household_memberships.create!(user: @user, role: "owner")
    @category = @household.budget_categories.create!(name: "Synthetic groceries", stack_key: "non_discretionary", sort_order: 0)
    @source = source([ movement(-1_000) ])
    @identity = link(@source)
  end

  test "actual income counts only current included positive income and keeps missing months unknown" do
    fresh = source([ movement(338_000, type: "income").merge(merchant: "Orchid Demo payroll"), movement(10_000, row: 2, type: "refund"), movement(20_000, row: 3, type: "transfer") ])
    identity = link(fresh)
    fresh[:events].each { |event| approve(stage(event, identity: identity, amount: event.signed_amount_cents, event_type: event.event_type, merchant: FinancialDocuments::SourceReview::ParticipantPlan.merchant_for(event), purchase: nil, category: nil)) }
    actual = HouseholdFinance::ActualIncome.new(@household)
    assert_equal 338_000, actual.month(Date.new(2026, 7, 1))[:actual_cents]
    assert actual.month(Date.new(2026, 7, 1))[:partial]
    assert_nil actual.month(Date.new(2026, 6, 1))[:actual_cents]
    answer = HouseholdFinance::MiaIncomeAnswer.new(@household, message: "How much did I make in July 2026?").response
    assert_includes answer, "$3,380 came in"
    future = actual.month(Date.current.next_month)
    refute future[:month_open]
    assert_includes future[:coverage_note], "has not started yet"
  end

  # Approves every line as read and declares the statement complete, as "Approve the rest" and "Nothing’s missing" do.
  def approve_statement(src, identity)
    src[:events].each { |event| approve(stage(event, identity: identity, amount: event.signed_amount_cents, event_type: event.event_type, purchase: nil, category: nil, posted_on: event.posted_on.iso8601)) }
    attest("complete", src)
  end

  def answer_line(src, line, decision)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    input = { lines: [ { event_id: line.event.id, decision: decision, expected_head: line.expected_head, shown: { event_type: line.event.event_type, category_id: nil } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, src[:revision], input).call }
    domain.heads.find_by!(financial_source_event: line.event).approved_version
  end

  def money_in(src, description)
    event = src[:events].sole
    event.financial_source_evidence.update!(payload: event.financial_source_evidence.payload.merge("merchant" => description, "raw_description" => description))
    FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole
  end

  test "legacy approved deposits reopen without rewriting approvals and count after the ownership answer" do
    src = source([ movement(40_000, type: "income", posted_on: "2026-07-06").merge(merchant: "ATM DEPOSIT"),
      movement(80_000, row: 2, type: "income").merge(merchant: "Orchid Demo payroll") ])
    identity = link(src, tracked: @identity.source_tracked_account)
    src[:events].each do |event|
      approve(stage(event, identity: identity, amount: event.signed_amount_cents, event_type: "income",
        merchant: FinancialDocuments::SourceReview::ParticipantPlan.merchant_for(event), purchase: nil, category: nil))
    end
    attest("complete", src)
    head = SourceReviewHead.find_by!(financial_source_event: src[:events].first)
    old_id = head.approved_version_id
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision])
    line = plan.lines.first
    assert_equal :money_in_source, line.kind
    refute line.done
    assert plan.lines.second.done
    july = HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))
    assert_equal [ 80_000, true, 1 ], july.values_at(:actual_cents, :partial, :waiting_deposits)
    assert_includes july[:coverage_note], "1 deposit still needs your answer in Review, so it isn't counted yet."
    assert_equal old_id, head.reload.approved_version_id
    %w[July year].each do |period|
      answer = HouseholdFinance::MiaIncomeAnswer.new(@household, message: "How much came in this #{period} 2026?").response
      assert_includes answer, "1 deposit still needs your answer in Review"
    end
    assert_equal Date.new(2026, 7, 7), answer_line(src, line, "someone_else").posted_on
    assert_equal 120_000, HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:actual_cents]
    assert FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.all?(&:done)
  end

  test "complete statements with different incoming payments waiting on ownership keep the month partial" do
    src = source([ movement(20_000, type: "income").merge(merchant: "Orchid Demo payroll"),
      movement(9_000, row: 2, type: "transfer").merge(merchant: "Zelle From Iris Demo"),
      movement(8_000, row: 3, type: "income").merge(merchant: "ATM DEPOSIT") ])
    identity = link(src, tracked: @identity.source_tracked_account)
    src[:events].each_with_index do |event, index|
      reference = [ nil, "ownership-needed", "overlap-cleared" ][index]
      approve(stage(event, identity: identity, amount: event.signed_amount_cents, event_type: event.event_type,
        merchant: FinancialDocuments::SourceReview::ParticipantPlan.merchant_for(event), purchase: nil, category: nil,
        external_reference: reference && "#{reference}:#{event.id}"))
    end
    attest("complete", src)
    july = HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))
    assert july[:partial]
    assert_equal 2, july[:waiting_deposits]
    assert_includes july[:coverage_note], "2 deposits still need your answer in Review"
  end

  test "round4 bill pay asks while specific payroll is ready" do
    [ [ "ACH CREDIT BILL PAY", :money_in_source ], [ "Orchid Demo PAYROLL", nil ], [ "Orchid Demo NET PAY", nil ] ].each do |merchant, kind|
      src = source([ movement(40_000, type: "income").merge(merchant: merchant) ])
      link(src)
      actual = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole.kind
      kind ? assert_equal(kind, actual) : assert_nil(actual)
    end
  end

  test "round4 approved include facts reopen even when the source was not posted" do
    src = source([ movement(40_000, type: "income").merge(merchant: "ATM DEPOSIT", row_kind: "unresolved") ])
    event = src[:events].sole
    identity = link(src)
    refute FinancialDocuments::SourceReview::ParticipantPlan.money_in_question?(event, "ATM DEPOSIT")
    approve(stage(event, identity: identity, amount: 42_000, event_type: "income", merchant: "Iris Demo deposit", purchase: nil, category: nil))
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole
    assert_equal :money_in_source, line.kind
    assert_equal 1, HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:waiting_deposits]
  end

  test "round4 reopened income shows approved facts and an edit records the received answer" do
    src = source([ movement(40_000, type: "income").merge(merchant: "ATM DEPOSIT") ])
    identity = link(src)
    approve(stage(src[:events].sole, identity: identity, amount: 42_000, event_type: "income", merchant: "Iris Demo deposit", posted_on: "2026-07-09", purchase: nil, category: nil))
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole
    row = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, src[:revision], user: @user).plan_summary[:attention].sole
    assert_equal [ 42_000, "2026-07-09", "Iris Demo deposit", "income" ], row.values_at(:amount_cents, :posted_on, :merchant, :event_type)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    input = { lines: [ { event_id: line.event.id, decision: "edited", expected_head: line.expected_head,
      edit: { kind: "money_in", amount_cents: 43_000, posted_on: "2026-07-10", merchant: "PAY PAL Iris Demo" } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, src[:revision], input).call }
    version = SourceReviewHead.find_by!(financial_source_event: line.event).approved_version
    assert_equal "received:#{line.event.id}", version.external_reference
    assert FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole.done
    assert_equal 43_000, HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:actual_cents]
  end

  test "round4 simulator money in edit finishes the ownership question" do
    require Rails.root.join("lib/scorecard/approval_simulator")
    src = source([ movement(40_000, type: "income").merge(merchant: "PAY PAL Iris Demo") ])
    link(src)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole
    key = Object.new
    key.define_singleton_method(:event) { |_| { "event_kind" => "income" } }
    simulator = Scorecard::ApprovalSimulator.new(household: @household, user: @user, answer_key: key, categories: {})
    entry = simulator.send(:answer_for, line, { "leg_id" => "invented-paypal", "signed_amount_cents" => 42_000, "date" => "2026-07-09" }, "2026-07")
    assert_equal "edited", entry[:decision]
    assert_equal "money_in", entry[:edit][:kind]
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, src[:revision], { lines: [ entry ] }).call }
    assert FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole.done
    assert_equal 42_000, HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:actual_cents]
  end

  test "round4 future income stays unknown even with approved payroll" do
    src = source([ movement(40_000, type: "income").merge(merchant: "Iris Demo payroll") ])
    identity = link(src)
    approve_statement(src, identity)
    assert_nil HouseholdFinance::ActualIncome.new(@household, today: Date.new(2026, 6, 30)).month(Date.new(2026, 7, 1))[:actual_cents]
  end

  test "wallet names with pay ask the money in question" do
    [ "Google Pay", "Samsung Pay", "Amazon Pay", "PAY PAL" ].each do |wallet|
      src = source([ movement(40_000, type: "income").merge(merchant: "#{wallet} Orchid Demo") ])
      link(src)
      line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole
      assert_equal :money_in_source, line.kind, wallet
    end
  end

  test "money into a card is never income, even approved as read" do
    card = source([ movement(50_000, type: "income").merge(merchant: "AUTOPAY PAYMENT") ], basis: "liability")
    card_identity = link(card)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, card[:revision]).lines.sole
    assert_equal :card_payment, line.kind
    assert_equal "debt_payment", answer_line(card, line, "as_read").event_type
    # Even a line saved as income on a card (as before this rule) counts nowhere.
    other = source([ movement(20_000, type: "income", posted_on: "2026-07-09") ], basis: "liability")
    approve(stage(other[:events].sole, identity: link(other, tracked: card_identity.source_tracked_account), amount: 20_000, event_type: "income", purchase: nil, category: nil, posted_on: "2026-07-09"))
    assert_nil HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:actual_cents]
  end

  test "money in that may be her own money is asked once and counts only when earned or received" do
    { "ATM DEPOSIT" => true, "Deposit from Savings" => true, "ACH CREDIT PAYPAL TRANSFER" => true, "DEPOSIT" => true,
      "Lina Talun payroll" => false, "SSA TREAS 310 SOC SEC" => false, "DIRECT DEPOSIT TALUN DEMO SERVICES" => false }.each do |description, asked|
      src = source([ movement(40_000, type: "income") ])
      link(src)
      line = money_in(src, description)
      asked ? assert_equal(:money_in_source, line.kind, description) : assert_nil(line.kind, description)
    end
    own = source([ movement(30_000, type: "income", posted_on: "2026-07-10") ])
    link(own)
    line = money_in(own, "Deposit from Savings")
    assert_equal "Money you earned or received, or your own money moving back?", FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, own[:revision], user: @user).plan_summary[:attention].find { |row| row[:event_id] == line.event.id }[:question]
    assert_equal "transfer", answer_line(own, line, "own_account").event_type
    earned = source([ movement(45_000, type: "income", posted_on: "2026-07-11") ])
    link(earned)
    version = answer_line(earned, money_in(earned, "ATM DEPOSIT"), "someone_else")
    assert_equal [ "income", "received:#{version.source_review_head.financial_source_event_id}" ], [ version.event_type, version.external_reference ]
    assert_equal 45_000, HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:actual_cents]
  end

  test "money received from a person asks whose money it was and counts when someone else sent it" do
    gift = source([ movement(25_000, type: "transfer") ])
    link(gift)
    line = money_in(gift, "Zelle From Mateo Demo")
    assert_equal :person_payment, line.kind
    assert_equal :person_payment, money_in(gift, "Received from Ana Demo").kind
    assert_equal "income", answer_line(gift, line, "someone_else").event_type
    back = source([ movement(15_000, type: "income", posted_on: "2026-07-12") ])
    link(back)
    assert_equal "transfer", answer_line(back, money_in(back, "Venmo cashout"), "own_account").event_type
    assert_equal 25_000, HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:actual_cents]
  end

  test "interest earned counts and a line still waiting on its answer does not" do
    savings = source([ movement(1_250, type: "interest"), movement(9_000, row: 2, type: "income", posted_on: "2026-07-08") ])
    identity = link(savings)
    approve(stage(savings[:events].first, identity: identity, amount: 1_250, event_type: "interest", purchase: nil, category: nil))
    event = savings[:events].second
    approve(run_operation(OPS::DraftStage, { event_id: event.id, base_version_id: nil, base_lock_version: 0, expected_pending_draft: nil, reason: "Participant said it is a different payment", projection: { action: "none" },
      facts: { source_account_identity_version_id: identity.id, disposition: "include", event_type: "income", signed_amount_cents: 9_000, purchase_amount_cents: nil, posted_on: "2026-07-08",
        merchant: "Zelle From Mateo Demo", budget_category_id: nil, overlap_disposition: "distinct", matched_version_id: nil, external_reference: "ownership-needed:#{event.id}" } }))
    assert_equal 1_250, HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:actual_cents]
  end

  test "coverage joins statement periods for each deposit account and ignores cards and investments" do
    # The setup statement for this account is not approved; two approved half-month statements cover July instead.
    first = source([ movement(300_000, type: "income", posted_on: "2026-07-01").merge(merchant: "Talun payroll") ], from: "2026-07-01", to: "2026-07-15")
    identity = link(first, tracked: @identity.source_tracked_account)
    approve_statement(first, identity)
    assert HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:partial]
    second = source([ movement(300_000, type: "income", posted_on: "2026-07-16").merge(merchant: "Talun payroll") ], from: "2026-07-16", to: "2026-07-31")
    approve_statement(second, link(second, tracked: identity.source_tracked_account))
    card = source([ movement(-4_000, posted_on: "2026-07-20") ], basis: "liability", from: "2026-07-10", to: "2026-08-09")
    approve(stage(card[:events].sole, identity: link(card), amount: -4_000, posted_on: "2026-07-20"))
    @household.accounts.create!(label: "Talun retirement", account_type: "retirement", balance_cents: 1_000_000, source_type: "manual_ui")
    july = HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))
    assert_equal [ 600_000, false ], july.values_at(:actual_cents, :partial)
    assert_includes july[:coverage_note], "From the statements you approved"
    @household.accounts.create!(label: "Talun savings", account_type: "savings", balance_cents: 50_000, source_type: "manual_ui")
    assert HouseholdFinance::ActualIncome.new(@household).month(Date.new(2026, 7, 1))[:partial]
  end

  test "a month only partly covered with nothing approved is not known rather than zero" do
    src = source([ movement(330_000, type: "income", posted_on: "2026-08-01").merge(merchant: "Talun payroll") ], from: "2026-07-25", to: "2026-08-24")
    approve_statement(src, link(src))
    actual = HouseholdFinance::ActualIncome.new(@household)
    july = actual.month(Date.new(2026, 7, 1))
    assert_nil july[:actual_cents]
    assert_equal "None approved yet. Your approved statements don’t cover all of this month.", july[:coverage_note]
    assert_equal [ 330_000, true ], actual.month(Date.new(2026, 8, 1)).values_at(:actual_cents, :partial)
  end

  # Counts statement reads made for income and every query, so Home and a Mia year turn read approved lines once.
  def income_reads
    reads = queries = 0
    reader = FinancialDocuments::SourceReview::ApprovedSourceReader
    original = reader.method(:new)
    reader.define_singleton_method(:new) do |*args|
      reads += 1 if caller_locations.first(8).any? { |location| location.path.end_with?("household_finance/actual_income.rb") }
      original.call(*args)
    end
    ActiveSupport::Notifications.subscribed(->(*args) { queries += 1 unless args.last[:name] == "SCHEMA" }, "sql.active_record") { yield }
    { reads: reads, queries: queries }
  ensure
    reader.singleton_class.remove_method(:new)
  end

  test "Home and a Mia year answer read the approved statements for income once" do
    @household.update!(created_at: Time.zone.local(2026, 1, 1))
    3.times do |index|
      src = source([ movement(330_000, type: "income").merge(merchant: "Talun payroll"), movement(-2_500, row: 2) ], period: "2026-0#{index + 4}")
      identity = link(src, tracked: @identity.source_tracked_account)
      approve(stage(src[:events].first, identity: identity, amount: 330_000, event_type: "income", purchase: nil, category: nil, posted_on: "2026-0#{index + 4}-07"))
      approve(stage(src[:events].second, identity: identity, amount: -2_500, posted_on: "2026-0#{index + 4}-07"))
    end
    home = income_reads { HouseholdFinance::DataPresenter.new(@household, user: @user).dashboard.to_json }
    year = income_reads { HouseholdFinance::MiaIncomeAnswer.new(@household, message: "How much have we brought in this year?").response }
    puts "ACTUAL_INCOME home_reads=#{home[:reads]} home_queries=#{home[:queries]} year_reads=#{year[:reads]} year_queries=#{year[:queries]}"
    assert_equal [ 1, 1 ], [ home[:reads], year[:reads] ]
    assert_operator year[:queries], :<=, 900
  end

  test "a year answer gives one total and names the months that are partial or not known" do
    travel_to Time.zone.local(2026, 12, 20, 12)
    @household.update!(created_at: Time.zone.local(2026, 1, 1))
    [ "2026-04", "2026-05" ].each do |period|
      src = source([ movement(330_000, type: "income").merge(merchant: "Talun payroll") ], period: period)
      approve(stage(src[:events].sole, identity: link(src, tracked: @identity.source_tracked_account), amount: 330_000, event_type: "income", purchase: nil, category: nil, posted_on: "#{period}-07"))
    end
    answer = HouseholdFinance::MiaIncomeAnswer.new(@household, message: "How much did we earn in 2026?").response
    assert_match(/\A\$6,600 came in for April to May 2026 from the lines you approved\./, answer)
    assert_includes answer, "April to May 2026 are only partly covered"
    assert_includes answer, "Not known yet: January to March and June to December 2026."
    assert_operator answer.scan(/[.?!](?:\s|\z)/).length, :<=, 5
  ensure
    travel_back
  end

  test "an approved line with a pending correction remains an individual question" do
    event = @source[:events].sole
    approve(stage(event))
    stage(event, amount: -999, merchant: "Talun Proposed Store", posted_on: "2026-07-08")
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, @source[:revision])
    refute plan.lines.sole.done
    assert_empty plan.ready_ids
    assert_empty plan.category_lines
    assert_empty plan.repeated_lines
    row = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, @source[:revision]).plan_summary[:attention].sole
    assert_equal :correction, row[:kind]
    assert_equal "Talun Proposed Store", row[:editable_merchant]
    assert_equal(-999, row[:signed_amount_cents])
    assert_equal "2026-07-08", row[:posted_on]
    assert_equal @category.id, row[:category_id]
    assert_equal 0, FinancialDocuments::SourceReview::ParticipantProgress.new(@household, @source[:revision]).call[:done]
  end

  test "store selector leaves pending corrections individual" do
    fresh = source([ movement(-1700), movement(-1800, row: 2), movement(-1900, row: 3) ])
    identity = link(fresh)
    stage(fresh[:events].first, identity: identity, amount: -999, merchant: "Corrected merchant")
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    assert_equal fresh[:events].drop(1).map(&:id), plan.category_lines.map { |line| line.event.id }
    assert_equal [ fresh[:events].drop(1).map(&:id) ], plan.category_groups.map { |group| group.map { |line| line.event.id } }
    other = source([ movement(-2100), movement(-2200, row: 2) ])
    other_identity = link(other)
    stage(other[:events].first, identity: other_identity, amount: -888, merchant: "Other correction")
    presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, fresh[:revision], user: @user)
    groups = presenter.send(:store_groups, plan, { @category.id => @category.name })
    assert_equal (@source[:events] + fresh[:events].drop(1) + [ other[:events].last ]).map(&:id).sort, groups.flatten.map { |row| row[:event_id] }.sort
  end

  test "locked store save preserves a pending correction" do
    fresh = source([ movement(-1700), movement(-1800, row: 2), movement(-1900, row: 3) ])
    identity = link(fresh)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    entries = plan.lines.map { |line| { revision_id: fresh[:revision].id, event_id: line.event.id, expected_head: line.expected_head, decision: "edited", edit: { category_id: @category.id } } }
    draft = stage(fresh[:events].first, identity: identity, amount: -999, posted_on: "2026-07-09", merchant: "Corrected merchant")
    before = draft.reload.attributes
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    assert_raises(FinancialDocuments::SourceReview::Domain::StaleReview) do
      @household.with_lock { FinancialDocuments::SourceReview::StoreCategoryApprover.call(domain, fresh[:revision], { store_lines: entries }) }
    end
    assert_equal before, draft.reload.attributes
    assert_nil draft.source_review_head.reload.approved_version_id
  end

  test "approved plus pending-only overlap cannot share a repeated-file answer" do
    approved = approve(stage(@source[:events].sole))
    pending_source = source([ movement(-1000) ])
    pending_identity = link(pending_source, tracked: @identity.source_tracked_account)
    stage(pending_source[:events].sole, identity: pending_identity)
    fresh = source([ movement(-1000) ])
    link(fresh, tracked: @identity.source_tracked_account)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    line = plan.lines.sole
    assert_equal :duplicate, line.kind
    assert_equal 2, line.overlaps.length
    assert_equal [ approved.id ], line.overlaps.filter_map { |row| row[:approved_version_id] }
    assert line.overlaps.any? { |row| row[:pending_draft_id] && !row[:approved_version_id] }
    assert_empty plan.repeated_lines
  end

  test "store groups share cleaned names but never include guarded questions and remember this file" do
    fresh = source([ movement(-1700).merge(merchant: "POS DEBIT Island Demo Mart"),
      movement(-1800, row: 2).merge(merchant: "Island Demo Mart"),
      movement(-1900, row: 3).merge(merchant: "Island Demo Mart", event_type: "transfer") ])
    link(fresh)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    assert_equal [ fresh[:events].first(2).map(&:id) ], plan.category_groups.map { |group| group.map { |line| line.event.id } }
    first = fresh[:events].first
    input = { lines: [ { event_id: first.id, decision: "edited", edit: { kind: "spending", category_id: @category.id } } ] }
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, fresh[:revision], input).call }
    after = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    remembered = after.line_for(fresh[:events].second.id)
    assert remembered.ready?
    assert remembered.as_before
    assert_equal @category.id, remembered.category_id
    refute remembered.done
    assert_equal "Island Demo Mart", remembered.merchant
    assert_equal :transfer, after.line_for(fresh[:events].last.id).kind
  end

  test "previous default category is ready as before on the next statement" do
    @category.update!(name: "Everyday spending", stack_key: "discretionary")
    approve(stage(@source[:events].sole, merchant: "Ross"))
    fresh = source([ movement(-1200) ])
    event = fresh[:events].sole
    event.financial_source_evidence.update!(payload: event.financial_source_evidence.payload.merge("merchant" => "Ross"))
    link(fresh)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision]).lines.sole
    assert line.ready?, line.kind.inspect
    assert line.as_before
    assert_equal @category.id, line.category_id
  end

  test "review one answer covers similar statement merchants after an explicit different split" do
    @household.budget_categories.create!(name: "Everyday spending", stack_key: "discretionary")
    fresh = source([ movement(-3500).merge(merchant: "Payless"), movement(-4100, row: 2).merge(merchant: "Cost-U-Less") ])
    identity = link(fresh)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    assert_equal 2, plan.attention.length
    approve(stage(fresh[:events].first, identity: identity, amount: -3500, merchant: "Payless"))
    after = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    other = after.line_for(fresh[:events].last.id)
    assert other.ready?, other.kind.inspect
    assert_equal @category.id, other.category_id
    assert_equal 1, after.lines.count(&:done)
  end

  test "review grocery and fuel statement lines use the everyday default despite an extracted bills label" do
    @category.update!(name: "Fixed essentials")
    everyday = @household.budget_categories.create!(name: "Everyday spending", stack_key: "discretionary")
    merchants = [ "Payless", "Cost-U-Less", "Shell", "Mobil" ]
    fresh = source(merchants.map.with_index { |merchant, i| movement(-3500 - i * 100, row: i + 1).merge(merchant: merchant) })
    payloads = fresh[:transaction_drafts].map do |payload|
      payload.merge(splits: [ { amount: payload[:total_amount], category_name: "Fixed essentials", stack_key: "non_discretionary", confidence: "high" } ])
    end
    result = HouseholdFinance::DocumentTransactionDraftPersister.new(fresh[:import], payloads).call
    assert_equal 4, result[:created_count]
    identity = link(fresh)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    assert_equal fresh[:events].map(&:id), plan.ready_ids
    assert_empty plan.attention
    plan.lines.each do |line|
      assert line.ready?
      assert_equal everyday.id, line.category_id
    end
    assert_empty @household.household_transactions

    # Her reviewed choice still takes priority on the next statement.
    @category = everyday
    approve(stage(fresh[:events].first, identity: identity, amount: -3500, merchant: "Payless"))
    next_source = source([ movement(-4500).merge(merchant: "Payless") ])
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, next_source[:revision]).lines.sole
    assert line.ready?
    assert line.as_before
    assert_equal everyday.id, line.category_id
  end

  test "reviewed zero activity statement can be complete while a blank or hidden movement cannot" do
    @source = source([ movement(0, type: "unknown") ])
    account = account_input(@source)
    @identity = run_operation(OPS::AccountLink, account.merge(statement_facts: account[:statement_facts].merge("printed_row_count_basis" => "all")))
    approve(stage(@source[:events].sole, disposition: "informational", amount: nil, purchase: nil, event_type: "unknown", overlap: "excluded"))
    approval = attest("complete")
    assert_equal "complete", approval.coverage_status
    assert_empty approval.deficiencies
    hidden = source([ movement(-100) ])
    identity = link(hidden)
    approve(stage(hidden[:events].sole, identity: identity, disposition: "informational", amount: nil, purchase: nil, event_type: "unknown", overlap: "excluded"))
    state = FinancialDocuments::SourceReview::ApprovalState.new(@household, hidden[:revision]).call
    assert_includes state[:deficiencies], "empty_source_history"
    assert_includes state[:deficiencies], "account_reconciliation_incomplete"
  end

  # Review of #197 (M1): spending approved through source review creates a
  # confirmed actual and flips only pending drafts, so an import whose
  # drafts were ignored first still holds approved values.
  test "source review approvals count as approved values for status, guards and Mia" do
    fresh = source([ movement(-1_000) ])
    import = fresh[:import]
    staged = HouseholdFinance::DocumentTransactionDraftPersister.new(import, fresh[:transaction_drafts]).call
    assert_equal 1, staged[:created_count]
    import.transaction_drafts.sole.update!(status: "ignored")
    refute import.approved_values?

    identity = link(fresh)
    assert import.approved_values?, "an approved account identity is an approved value"
    project(approve(stage(fresh[:events].sole, identity: identity)))
    actual = @household.household_transactions.find_by!(source_import: import)
    assert_equal "confirmed", actual.status
    assert_equal "ignored", import.transaction_drafts.sole.reload.status
    @identity = identity
    @source = fresh
    attest("qualified")

    import.update!(metadata: import.metadata.merge("source_accounting_review_pending" => false))
    HouseholdFinance::DocumentImportStatusReconciler.new(import).call
    assert_equal "applied", import.reload.status
    assert_includes @household.financial_document_imports.with_approved_values, import
  end

  test "staging and cancelling do not change actuals or hide an approved head" do
    approved = approve(stage(@source[:events].first))
    head = approved.source_review_head
    draft = stage(@source[:events].first, amount: -900)
    assert_equal approved.id, head.reload.approved_version_id
    assert_equal 1_000, reader[:rows].sole[:purchase_amount_cents]
    assert_equal 1, reader[:revisions].sole[:state][:pending_corrections]
    assert_empty @household.household_transactions
    run_operation(OPS::DraftCancel, draft_input(draft))
    assert_equal "cancelled", draft.reload.status
    assert_equal approved.id, head.reload.approved_version_id
  end

  test "approved corrections append facts and preserve original immutable extraction" do
    original = @source[:events].first
    first = approve(stage(original))
    second = approve(stage(original, amount: -900, reason: "Corrected from the synthetic source page"))
    assert_equal first.id, second.supersedes_id
    assert_equal 2, second.version_number
    assert_equal(-1_000, original.reload.signed_amount_cents)
    assert_equal(-1_000, first.reload.signed_amount_cents)
    assert_equal(-900, second.signed_amount_cents)
    assert_raises(ActiveRecord::ReadOnlyRecord) { second.update!(signed_amount_cents: -800) }
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { SourceReviewVersion.where(id: second.id).update_all(signed_amount_cents: -800) }
    end
    original.financial_source_evidence.destroy!
    assert_equal "Synthetic merchant", second.reload.merchant
  end

  test "participant merchant wording survives staging approval read-back and spending projection" do
    merchant = "Ross Dress for Less"
    draft = stage(@source[:events].sole, merchant: merchant)
    assert_equal merchant, draft.facts["merchant"]
    version = approve(draft)
    assert_equal merchant, version.reload.merchant
    assert_equal merchant, reader[:rows].sole[:merchant]
    assert_equal merchant, reader[:canonical_rows].sole[:merchant]
    project(version)
    assert_equal merchant, @household.household_transactions.sole.merchant

    corrected = approve(stage(@source[:events].sole, merchant: "CARD PURCHASE 1776 COFFEE", reason: "Participant corrected the merchant"))
    assert_equal "CARD PURCHASE 1776 COFFEE", corrected.reload.merchant
    assert_equal "CARD PURCHASE 1776 COFFEE", reader[:rows].sole[:merchant]
  end

  test "stale proposal fingerprints fail before changing approved versions" do
    draft = stage(@source[:events].first)
    operation = OPS::DraftApprove.new(@household, user: @user)
    prepared = operation.prepare(draft_input(draft))
    stage(@source[:events].first, amount: -900)
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) { operation.execute!(prepared, source: "manual") }
    assert_nil draft.source_review_head.reload.approved_version_id
    assert_equal 0, SourceReviewVersion.where(household: @household).count
  end

  test "current participant writable permission is checked again at execution and replay" do
    draft = stage(@source[:events].first)
    operation = OPS::DraftApprove.new(@household, user: @user)
    prepared = operation.prepare(draft_input(draft))
    @user.update!(invitation_status: "revoked")
    assert_raises(ArgumentError) { operation.execute!(prepared, source: "manual") }
    @user.update!(invitation_status: "accepted")
    approved = approve(draft)
    @household.household_memberships.find_by!(user: @user).update!(role: "coach_viewer")
    assert_raises(ArgumentError) { operation.authorize_replay!(approved) }
    assert OPS::DraftApprove::ACTOR_REQUIRED
    assert OPS::DraftApprove::SENSITIVE_AUDIT
  end

  test "unknown rows cannot silently become approved posted facts but informational exclusions are reviewed" do
    assert_raises(ArgumentError) { stage(@source[:events].first, amount: nil) }
    assert_raises(ArgumentError) { stage(@source[:events].first, event_type: "refund", amount: -1_000) }
    approved = approve(stage(@source[:events].first, disposition: "informational", amount: nil, purchase: nil, event_type: "unknown", overlap: "excluded"))
    assert_equal "informational", approved.disposition
    assert_nil approved.signed_amount_cents
    assert_empty @household.household_transactions
  end

  test "explicit expense replacement preserves old positive amounts and voiding never creates negative spending" do
    first = approve(stage(@source[:events].first, projection: { action: "create" }))
    old = first.source_projection_revision.replacement_transaction
    assert_equal 1_000, old.total_amount_cents
    second = approve(stage(@source[:events].first, amount: -900, projection: { action: "replace", transaction_id: old.id, expected_digest: FinancialDocuments::SourceReview::ProjectionCorrector.snapshot_digest(old) }))
    replacement = second.source_projection_revision.replacement_transaction
    assert_equal 900, replacement.total_amount_cents
    assert_equal "ignored", old.reload.status
    assert_equal 1_000, old.total_amount_cents
    third = approve(stage(@source[:events].first, disposition: "exclude", overlap: "excluded", projection: { action: "void", transaction_id: replacement.id, expected_digest: FinancialDocuments::SourceReview::ProjectionCorrector.snapshot_digest(replacement) }))
    assert_nil third.source_projection_revision.replacement_transaction
    assert_equal "ignored", replacement.reload.status
    assert_equal [ 900, 1_000 ], @household.household_transactions.order(:total_amount_cents).pluck(:total_amount_cents)
  end

  test "source account identity is reviewed across months and remapping marks previous facts stale" do
    approved = approve(stage(@source[:events].first))
    second_source = source([ movement(-500, posted_on: "2026-08-07") ], period: "2026-08")
    second_identity = link(second_source, tracked: @identity.source_tracked_account)
    assert_equal @identity.source_tracked_account_id, second_identity.source_tracked_account_id
    head = @identity.source_account_review_head
    run_operation(OPS::AccountLink, account_input(@source).merge(base_version_id: @identity.id, base_lock_version: head.reload.lock_version, label: "Corrected separate account"))
    refute reader[:rows].sole[:account_identity_current]
    assert_equal approved.id, reader[:rows].sole[:id]
    assert_includes reader[:revisions].sole[:state][:deficiencies], "account_identity_changed"
  end

  test "pending exact copies require canonical choice and cannot both create spending" do
    copy = source([ movement(-1_000) ], checksum: @source[:import].checksum_sha256)
    copy_identity = link(copy, tracked: @identity.source_tracked_account)
    first_draft = stage(@source[:events].first, overlap: "canonical", projection: { action: "create" })
    second_draft = stage(copy[:events].first, identity: copy_identity, overlap: "canonical", projection: { action: "create" })
    first = approve(first_draft)
    assert_raises(ArgumentError) { approve(second_draft) }
    matched = approve(stage(copy[:events].first, identity: copy_identity, disposition: "match", overlap: "match", matched_version_id: first.id))
    assert_equal first.id, matched.matched_version_id
    assert_equal 1, @household.household_transactions.count
  end

  test "date and amount alone are ambiguous while repeated genuine rows on one file survive" do
    other = source([ movement(-1_000) ])
    other_identity = link(other, tracked: @identity.source_tracked_account)
    assert_raises(ArgumentError) { approve(stage(@source[:events].first)) }
    first = approve(stage(@source[:events].first, overlap: "distinct"))
    second = approve(stage(other[:events].first, identity: other_identity, overlap: "distinct"))
    assert_equal "include", first.disposition
    assert_equal "include", second.disposition
    genuine = source([ movement(-200, row: 1), movement(-200, row: 2) ], period: "2026-09")
    genuine_identity = link(genuine)
    genuine[:events].each { |event| approve(stage(event, identity: genuine_identity, amount: -200, posted_on: "2026-09-07")) }
    assert_equal 2, SourceReviewVersion.joins(:source_review_head).where(source_review_heads: { financial_source_event_id: genuine[:events].map(&:id) }).count
  end

  test "complete source approval requires every current version and explicit coverage with balanced reviewed headers" do
    assert_raises(ArgumentError) { attest("complete") }
    approved = approve(stage(@source[:events].first))
    coverage = attest("complete")
    assert_equal "complete", coverage.coverage_status
    assert reader[:revisions].sole[:participant_approved]
    draft = stage(@source[:events].first, amount: -900)
    assert_equal "complete", reader[:revisions].sole[:coverage_status]
    approve(draft)
    assert_equal "stale", reader[:revisions].sole[:coverage_status]
    assert_equal [ approved.id ], coverage.source_version_ids
    assert_raises(ArgumentError) { attest("complete") }
    qualified = attest("qualified")
    assert_equal "qualified", qualified.coverage_status
    assert_includes qualified.deficiencies, "account_reconciliation_incomplete"
  end

  test "unknown page coverage and deleted evidence cannot be newly called complete" do
    approve(stage(@source[:events].first))
    @source[:import].update!(source_deleted_at: Time.current, s3_key: nil, status: "source_deleted")
    assert_raises(ArgumentError) { attest("complete") }
    assert_equal "qualified", attest("qualified").coverage_status
    assert_equal(-1_000, reader[:rows].sole[:signed_amount_cents])
  end

  test "transfer pairing requires participant-approved opposing legs and rejects over-allocation" do
    bank = approve(stage(@source[:events].first, event_type: "transfer", purchase: nil))
    received_source = source([ movement(1_000, type: "transfer", posted_on: "2026-07-08") ])
    received_identity = link(received_source)
    received = approve(stage(received_source[:events].first, identity: received_identity, amount: 1_000, event_type: "transfer", purchase: nil, posted_on: "2026-07-08"))
    members = [ { source_review_version_id: bank.id, role: "movement", allocation_cents: 1_000 }, { source_review_version_id: received.id, role: "movement", allocation_cents: 1_000 } ]
    group = run_operation(OPS::EconomicLink, group_input("transfer", members))
    assert_equal "transfer", group.kind
    assert_empty @household.household_transactions
    assert_raises(ArgumentError) { run_operation(OPS::EconomicLink, group_input("transfer", members)) }
    refute reader[:rows].sole[:spending_eligible]
  end

  test "split funding stages one full purchase only after a reviewed economic link" do
    wallet = approve(stage(@source[:events].first, amount: -1_000, purchase: 10_000))
    refute reader[:rows].sole[:spending_eligible]
    assert_raises(ArgumentError) { project(wallet) }
    funding_source = source([ movement(-9_000, type: "transfer", posted_on: "2026-07-08") ])
    funding_identity = link(funding_source)
    funding = approve(stage(funding_source[:events].first, identity: funding_identity, amount: -9_000, event_type: "transfer", purchase: nil, posted_on: "2026-07-08"))
    run_operation(OPS::EconomicLink, group_input("purchase_funding", [ { source_review_version_id: wallet.id, role: "purchase", allocation_cents: 1_000 }, { source_review_version_id: funding.id, role: "funding", allocation_cents: 9_000 } ]))
    assert reader[:rows].sole[:spending_eligible]
    projected = project(wallet)
    assert_equal 10_000, projected.replacement_transaction.total_amount_cents
    assert_equal 1, @household.household_transactions.count
  end

  test "matching aliases resolve one canonical fact and become stale when that target changes" do
    copy = source([ movement(-1_000) ], checksum: @source[:import].checksum_sha256)
    identity = link(copy, tracked: @identity.source_tracked_account)
    first = approve(stage(@source[:events].first, overlap: "canonical"))
    alias_version = approve(stage(copy[:events].first, identity: identity, disposition: "match", overlap: "match", matched_version_id: first.id))
    view = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ copy[:revision].id ])
    assert_equal [ alias_version.id ], view[:rows].pluck(:id)
    assert_equal [ first.id ], view[:canonical_rows].pluck(:id)
    assert_equal [ @source[:revision].id ], view[:dependency_revision_ids]
    before = FinancialDocuments::SourceReview::ApprovalState.new(@household, copy[:revision]).call
    approve(stage(@source[:events].first, amount: -900))
    after = FinancialDocuments::SourceReview::ApprovalState.new(@household, copy[:revision]).call
    refute_equal before[:content_digest], after[:content_digest]
    assert_includes after[:deficiencies], "matched_source_fact_changed"
    assert_empty FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ copy[:revision].id ])[:canonical_rows]
  end

  test "economic link changes stale prior coverage while pending correction does not" do
    bank = approve(stage(@source[:events].first, event_type: "transfer", purchase: nil))
    attest("complete")
    other = source([ movement(1_000, type: "transfer", posted_on: "2026-07-08") ])
    identity = link(other)
    received = approve(stage(other[:events].first, identity: identity, amount: 1_000, event_type: "transfer", purchase: nil, posted_on: "2026-07-08"))
    run_operation(OPS::EconomicLink, group_input("transfer", [ { source_review_version_id: bank.id, role: "movement", allocation_cents: 1_000 }, { source_review_version_id: received.id, role: "movement", allocation_cents: 1_000 } ]))
    assert_equal "stale", reader[:revisions].find { |row| row[:id] == @source[:revision].id }[:coverage_status]
    assert_equal 1, reader[:economic_groups].length
  end

  test "refunds retain positive inflow and never create positive spending" do
    original = approve(stage(@source[:events].first))
    credit = source([ movement(500, type: "refund", posted_on: "2026-07-08") ])
    identity = link(credit, tracked: @identity.source_tracked_account)
    refunded = approve(stage(credit[:events].first, identity: identity, amount: 500, purchase: nil, event_type: "refund", posted_on: "2026-07-08"))
    group = run_operation(OPS::EconomicLink, group_input("refund", [ { source_review_version_id: original.id, role: "original_purchase", allocation_cents: 500 }, { source_review_version_id: refunded.id, role: "refund", allocation_cents: 500 } ]))
    assert_equal "refund", group.kind
    assert_equal 500, refunded.signed_amount_cents
    assert_raises(ArgumentError) { project(refunded) }
    assert_empty @household.household_transactions
  end

  test "strict dates cents direction and projection actions fail without mutation" do
    assert_raises(ArgumentError) { stage(@source[:events].first, amount: -10.5) }
    assert_raises(ArgumentError) { stage(@source[:events].first, posted_on: "2026-08-01") }
    assert_raises(ArgumentError) { stage(@source[:events].first, posted_on: "July 7, 2026") }
    assert_raises(ArgumentError) { stage(@source[:events].first, amount: 1_000) }
    assert_raises(ArgumentError) { OPS::DraftStage.new(@household, user: @user).prepare(event_id: @source[:events].first.id, base_version_id: nil, base_lock_version: 0, facts: {}, projection: { action: "create", transaction_id: 1 }, reason: "Synthetic reason") }
    assert_empty SourceReviewVersion.where(household: @household)
  end

  test "inactive categories and failed projection roll back an approval atomically" do
    draft = stage(@source[:events].first, projection: { action: "create" })
    @category.update!(active: false)
    assert_raises(ArgumentError) { approve(draft) }
    assert_equal "pending", draft.reload.status
    assert_nil draft.source_review_head.reload.approved_version_id
    assert_empty @household.household_transactions
    assert_empty SourceReviewVersion.where(household: @household)
  end

  test "cross household IDs and SQL approved head substitution fail closed" do
    foreign = Household.create!(created_by_user: @user, name: "Other synthetic household")
    foreign.household_memberships.create!(user: @user, role: "partner")
    assert_raises(ActiveRecord::RecordNotFound) { OPS::DraftApprove.new(foreign, user: @user).prepare(draft_input(stage(@source[:events].first))) }
    first = approve(stage(@source[:events].first))
    second_source = source([ movement(-200, row: 2) ])
    identity = link(second_source)
    second = approve(stage(second_source[:events].first, identity: identity, amount: -200))
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { SourceReviewHead.where(id: first.source_review_head_id).update_all(approved_version_id: second.id) }
    end
    assert_raises(ArgumentError) { OPS::DraftApprove.new(foreign, user: @user).authorize_replay!(first) }
    assert_equal first.id, first.source_review_head.reload.approved_version_id
  end

  test "unknown page coverage remains qualified despite balanced reviewed financial facts" do
    original = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic-unknown.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf")
    attempt = original.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "v1", schema_version: 2, status: "processing", started_at: Time.current)
    contract = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION, accounts: [ { account_key: "unknown", account_basis: "asset", period_start_on: "2026-07-01", period_end_on: "2026-07-31", opening_balance_cents: 20_000, closing_balance_cents: 19_000, printed_debit_cents: 1_000, printed_credit_cents: 0 } ], events: [ movement(-1_000).merge(account_key: "unknown") ] })
    @source = FinancialDocuments::SourceAccountingPersister.new(original, attempt: attempt, accounting: contract).call.merge(import: original)
    @identity = link(@source)
    approve(stage(@source[:events].first, overlap: "distinct"))
    assert_raises(ArgumentError) { attest("complete") }
    assert_includes attest("qualified").deficiencies, "document_page_or_sheet_coverage_unverified"
  end

  test "canonical account optional ledger link survives reuse and can be nullified without erasing reviewed facts" do
    account = @household.accounts.create!(label: "Synthetic checking ledger", account_type: "checking")
    head = @identity.source_account_review_head
    linked = run_operation(OPS::AccountLink, account_input(@source).merge(base_version_id: @identity.id, base_lock_version: head.reload.lock_version, account_id: account.id))
    extra = source([ movement(-400) ], period: "2026-08")
    reused = link(extra, tracked: linked.source_tracked_account)
    assert_equal account.id, reused.source_tracked_account.account_id
    account.destroy!
    assert_nil linked.source_tracked_account.reload.account_id
    assert_equal "asset", linked.source_tracked_account.account_basis
    assert_equal linked.id, linked.source_account_review_head.reload.approved_version_id
  end

  test "logical review head identity cannot be switched by SQL" do
    first = approve(stage(@source[:events].first))
    extra = source([ movement(-400) ], period: "2026-08")
    assert_raises(ActiveRecord::StatementInvalid) do
      ApplicationRecord.transaction(requires_new: true) { SourceReviewHead.where(id: first.source_review_head_id).update_all(financial_source_event_id: extra[:events].first.id) }
    end
    assert_equal @source[:events].first.id, first.source_review_head.reload.financial_source_event_id
  end

  test "correction flags all affected coverage and matched imports as requiring renewed review" do
    copy = source([ movement(-1_000) ], checksum: @source[:import].checksum_sha256)
    identity = link(copy, tracked: @identity.source_tracked_account)
    first = approve(stage(@source[:events].first, overlap: "canonical"))
    approve(stage(copy[:events].first, identity: identity, disposition: "match", overlap: "match", matched_version_id: first.id))
    copy[:import].update!(metadata: copy[:import].metadata.merge("source_accounting_review_pending" => false))
    approve(stage(@source[:events].first, amount: -900))
    assert copy[:import].reload.metadata["source_accounting_review_pending"]
    assert @source[:import].reload.metadata["source_accounting_review_pending"]
  end

  test "baseline reader digest pins the exact declared coverage version" do
    approve(stage(@source[:events].first))
    attest("complete")
    first = reader
    refute_includes first[:revisions].sole[:state][:reconciliation][:accounts].sole[:limitations], "printed_row_count_unknown"
    attest("complete")
    second = reader
    refute_equal first[:revisions].sole[:approval_id], second[:revisions].sole[:approval_id]
    refute_equal first[:digest], second[:digest]
    assert_equal first[:revisions].sole[:content_digest], second[:revisions].sole[:content_digest]
  end

  test "typed source rows stay in source review while manual drafts remain in the legacy queue" do
    typed = @household.transaction_drafts.create!(occurred_on: Date.new(2026, 7, 7), merchant: "Typed source row",
      total_amount_cents: 1000, source_type: "statement", status: "pending", financial_source_event: @source[:events].sole,
      financial_document_import: @source[:import])
    manual = @household.transaction_drafts.create!(occurred_on: Date.new(2026, 7, 7), merchant: "Manual reported row",
      total_amount_cents: 1000, source_type: "manual_chat", status: "pending")
    plan = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).plan_data
    assert_equal [ manual.id ], plan.fetch(:pending_transaction_drafts).pluck(:id)
    assert_equal 1, plan.fetch(:pending_transaction_drafts_meta).fetch(:total_count)
    assert_equal "pending", typed.reload.status
    assert_empty @household.household_transactions
  end

  test "review person detector excludes merchants billers and debt and keeps edited categories" do
    [ [ "PAYPAL *EBAY.COM", "purchase", false ], [ "PAYPAL *NETFLIX.COM", "purchase", false ], [ "Payment to Guam Power Authority", "purchase", false ], [ "Payment to Chase card ending 1234", "debt_payment", false ], [ "Zelle to Ana Cruz", "purchase", true ] ].each do |merchant, type, person|
      payment = source([ movement(-4599, type: type).merge(merchant: merchant) ])
      link(payment)
      event = payment[:events].sole
      assert_equal person, FinancialDocuments::SourceReview::TransferPairs.person_payment?(event, merchant), merchant
      line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
      assert_equal :card_payment, line.kind if type == "debt_payment"
      domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
      input = { lines: [ { event_id: event.id, decision: "edited", expected_head: line.expected_head,
        edit: { kind: type == "debt_payment" ? "card" : "spending", category_id: @category.id } } ] }
      @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
      assert_equal @category.id, domain.heads.find_by!(financial_source_event: event).approved_version.budget_category_id unless type == "debt_payment"
    end
  end

  test "an explicit category on a person-worded line is never replaced" do
    payment = source([ movement(-4599).merge(merchant: "Payment to Ana Cruz") ])
    link(payment)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    entry = { event_id: line.event.id, decision: "edited", expected_head: line.expected_head, edit: { kind: "spending", category_id: @category.id } }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], { lines: [ entry ] }).call }
    assert_equal @category.id, domain.heads.find_by!(financial_source_event: line.event).approved_version.budget_category_id
  end

  test "incoming person wording and open spreadsheet directions cannot be paired away" do
    debit = source([ movement(-2500, type: "transfer") ])
    credit = source([ movement(2500, type: "transfer").merge(merchant: "Zelle from Mom") ])
    link(debit)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings ending 4412"))
    pairs = FinancialDocuments::SourceReview::TransferPairs
    assert_nil pairs.new(@household).candidate(debit[:events].sole)
    event = credit[:events].sole
    event.financial_source_evidence.update!(payload: event.financial_source_evidence.payload.merge("merchant" => "Transfer from checking"))
    assert pairs.new(@household).candidate(debit[:events].sole)
    blocked = source([ movement(2800, type: "transfer") ], coverage: { signed_amount_question: true })
    blocked[:import].update!(filename: "unanswered.csv", content_type: "text/csv")
    outgoing = source([ movement(-2800, type: "transfer") ])
    link(outgoing)
    run_operation(OPS::AccountLink, account_input(blocked).merge(label: "Talun blocked savings"))
    assert_nil pairs.new(@household).candidate(outgoing[:events].sole)
    multi = source([ movement(3200, type: "transfer"), movement(nil, row: 2, type: "unknown").merge(account_key: "unclear-account", limitations: [ "transaction_direction_unclear" ], source_amount_text: "25.00") ],
      extra_accounts: [ { account_key: "unclear-account", account_basis: "asset" } ])
    multi[:import].update!(filename: "multi.csv", content_type: "text/csv")
    clear_account = multi[:events].find { |event| event.signed_amount_cents == 3200 }.financial_source_account
    run_operation(OPS::AccountLink, { source_account_id: clear_account.id, account_basis: "asset", label: "Talun multi savings", base_version_id: nil, base_lock_version: 0, statement_facts: {}, reason: "Verified synthetic account" })
    questions = FinancialDocuments::SpreadsheetSignAnswer.account_questions(multi[:revision])
    assert_equal 1, questions.length
    assert questions.sole[:answerable]
    other_debit = source([ movement(-3200, type: "transfer") ])
    link(other_debit)
    assert_nil pairs.new(@household).candidate(other_debit[:events].sole)
    refute FinancialDocuments::SpreadsheetSignAnswer.saved_decisions?(multi[:revision])
  end

  test "scorecard reviews an unmatched pair separately even without corrections or a mapping" do
    require Rails.root.join("lib/scorecard/approval_simulator")
    debit = source([ movement(-2500, type: "transfer") ])
    credit = source([ movement(2500, type: "transfer") ])
    link(debit)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings ending 4412"))
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, debit[:revision]).lines.sole
    key = Object.new
    def key.event(answer) = answer.fetch("expected")
    simulator = Scorecard::ApprovalSimulator.new(household: @household, user: @user, answer_key: key, categories: {}, correct_proposals: false)
    answer = { "leg_id" => "outgoing", "signed_amount_cents" => -2500, "date" => "2026-07-07", "expected" => { "event_kind" => "transfer_own_accounts" } }
    simulator.row_answers[credit[:events].sole.id] = { "expected" => { "event_kind" => "purchase" } }
    [ answer, nil ].each do |mapping|
      entry = simulator.send(:answer_for, line, mapping, "2026-07")
      assert_equal "edited", entry[:decision]
      assert_equal "moved", entry[:edit][:kind]
    end
  end

  test "participant pairs opposing reviewed accounts and can unpair without spending" do
    debit = source([ movement(-2500, type: "purchase").merge(merchant: "Zelle to Lina Talun") ])
    credit = source([ movement(2500, type: "transfer") ])
    link(debit)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings ending 4412"))
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, debit[:revision])
    line = plan.lines.sole
    assert_equal :transfer_pair, line.kind
    pair = line.pair
    prompt = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, debit[:revision], user: @user).context(event_ids: [ line.event.id ])
    assert_equal FinancialDocuments::SourceReview::ParticipantPlan.merchant_for(pair[:event]), prompt[:plan][:attention].sole[:transfer_pair][:description]
    input = { lines: [ { event_id: line.event.id, decision: "pair_transfer", expected_head: line.expected_head,
      shown: { event_type: "purchase", category_id: nil }, transfer_pair: { event_id: pair[:event].id, approved_version_id: nil, account_version_id: pair[:identity].id } } ] }
    stale = input.deep_dup
    stale[:lines].first[:transfer_pair][:account_version_id] += 1
    assert_raises(FinancialDocuments::SourceReview::Domain::StaleReview) do
      @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, debit[:revision], stale).call }
    end
    assert_empty domain.heads.where(financial_source_event: debit[:events].sole)
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, debit[:revision], input).call }
    group = FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(line.event)
    assert_equal 2, group.source_economic_memberships.count
    presented = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, debit[:revision], user: @user).context(event_ids: [ line.event.id ])
    assert_equal line.event.id, presented[:transfer_pairs].sole[:event_id]
    retry_result = @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, debit[:revision], input).call }
    assert_equal 2, retry_result[:unchanged]
    assert_empty @household.household_transactions
    fresh = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, debit[:revision]).lines.sole
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, debit[:revision], { lines: [ { event_id: line.event.id, decision: "unpair_transfer", expected_head: fresh.expected_head } ] }).call }
    assert_nil FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(line.event)
    assert_nil FinancialDocuments::SourceReview::TransferPairs.new(@household).candidate(line.event)
    reopened = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, debit[:revision]).lines.sole
    refute reopened.done
    assert_equal :person_payment, reopened.kind
    assert_empty @household.household_transactions
  end

  test "transfer suggestions refuse ambiguous same account and distant movements" do
    debit = source([ movement(-2500, type: "transfer") ])
    credit = source([ movement(2500, type: "transfer") ])
    link(debit, tracked: @identity.source_tracked_account)
    link(credit, tracked: @identity.source_tracked_account)
    pairs = FinancialDocuments::SourceReview::TransferPairs
    assert_nil pairs.new(@household).candidate(debit[:events].sole)
    head = SourceAccountReviewHead.find_by!(financial_source_account: credit[:revision].financial_source_accounts.sole)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings ending 4412", base_version_id: head.approved_version_id, base_lock_version: head.lock_version))
    assert pairs.new(@household).candidate(debit[:events].sole)
    duplicate = source([ movement(2500, type: "transfer") ])
    run_operation(OPS::AccountLink, account_input(duplicate).merge(label: "Talun wallet"))
    assert_nil pairs.new(@household).candidate(debit[:events].sole)
    distant_debit = source([ movement(-4000, type: "transfer") ])
    distant_credit = source([ movement(4000, type: "transfer", posted_on: "2026-07-12") ])
    link(distant_debit, tracked: @identity.source_tracked_account)
    run_operation(OPS::AccountLink, account_input(distant_credit).merge(label: "Talun distant savings"))
    assert_nil pairs.new(@household).candidate(distant_debit[:events].sole)
  end

  test "logged person purchases retain duplicate and ownership guards" do
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.iso8601("2026-07-07"))
    transaction = @household.household_transactions.create!(budget_period: period, occurred_on: "2026-07-07", merchant: "Venmo Ana Cruz", total_amount_cents: 4000, source_type: "manual_ui", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: @category, amount_cents: 4000)
    first = source([ movement(-4000).merge(merchant: "VENMO *ANA CRUZ") ])
    link(first, tracked: @identity.source_tracked_account)
    assert_equal :same_purchase, FinancialDocuments::SourceReview::ParticipantPlan.new(@household, first[:revision]).lines.sole.kind
    second = source([ movement(-4000, posted_on: "2026-07-08").merge(merchant: "VENMO *ANA CRUZ") ])
    link(second, tracked: @identity.source_tracked_account)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    plan = ->(src) { FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision]).lines.sole }
    assert_equal :duplicate, plan.call(second).kind
    [ [ second, :same_purchase ], [ second, :person_payment ] ].each do |src, next_kind|
      line = plan.call(src)
      @household.with_lock do
        FinancialDocuments::SourceReview::LineApprover.new(domain, src[:revision], { lines: [ { event_id: line.event.id, decision: "different", expected_head: line.expected_head, shown: { event_type: line.event.event_type, category_id: line.category_id } } ] }).call
      end
      fresh = plan.call(src)
      assert_equal next_kind, fresh.kind
      if next_kind == :same_purchase
        assert_raises(ArgumentError) do
          @household.with_lock do
            FinancialDocuments::SourceReview::LineApprover.new(domain, src[:revision], { lines: [ { event_id: fresh.event.id, decision: "edited", expected_head: fresh.expected_head, edit: { kind: "spending", merchant: fresh.merchant, posted_on: "2026-07-08", amount_cents: 4000, category_id: @category.id } } ] }).call
          end
        end
      end
      refute fresh.done
      assert_equal [ transaction.id ], @household.household_transactions.pluck(:id)
    end
  end

  test "different logged person purchase asks ownership before any category spending" do
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.iso8601("2026-07-07"))
    transaction = @household.household_transactions.create!(budget_period: period, occurred_on: "2026-07-07", merchant: "Venmo Ana Cruz", total_amount_cents: 4000, source_type: "manual_ui", status: "confirmed")
    transaction.transaction_splits.create!(budget_category: @category, amount_cents: 4000)
    payment = source([ movement(-4000).merge(merchant: "VENMO *ANA CRUZ") ])
    link(payment)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    assert_equal :same_purchase, line.kind
    @household.with_lock do
      FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], { lines: [ { event_id: line.event.id, decision: "different", expected_head: line.expected_head, shown: { event_type: "purchase", category_id: line.category_id } } ] }).call
    end
    fresh = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    assert_equal :person_payment, fresh.kind
    refute fresh.done
    assert_equal [ transaction.id ], @household.household_transactions.pluck(:id)
  end

  test "answered spreadsheet capability does not permanently block transfer candidates" do
    debit = source([ movement(-2500, type: "transfer") ], coverage: { signed_amount_answerable: true, signed_amount_question: false })
    debit[:import].update!(filename: "answered.csv", content_type: "text/csv")
    credit = source([ movement(2500, type: "transfer") ])
    link(debit)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Talun savings"))
    assert FinancialDocuments::SourceReview::TransferPairs.new(@household).candidate(debit[:events].sole)
  end

  test "own account answer removes a proposed purchase from pending Budget without spending" do
    payment = source([ movement(-1500).merge(merchant: "Venmo to Talun wallet") ])
    link(payment)
    event = payment[:events].sole
    draft = @household.transaction_drafts.create!(financial_source_event: event, financial_document_import: payment[:import],
      occurred_on: event.posted_on, merchant: "Venmo to Talun wallet", total_amount_cents: 1500, source_type: "statement", status: "pending", draft_payload: {})
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    input = { lines: [ { event_id: event.id, decision: "own_account", expected_head: line.expected_head, shown: { event_type: "purchase", category_id: line.category_id } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    assert_equal "ignored", draft.reload.status
    assert_equal "transfer", domain.heads.find_by!(financial_source_event: event).approved_version.event_type
    assert_empty @household.household_transactions
  end

  test "an archived support category gives a plain recovery and leaves the payment unanswered" do
    @household.budget_categories.create!(name: "Family Support", stack_key: "non_discretionary", active: false)
    payment = source([ movement(-3500, type: "transfer").merge(merchant: "Zelle to Lina Talun") ])
    link(payment)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    error = assert_raises(ArgumentError) do
      @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], { lines: [ { event_id: line.event.id, decision: "someone_else", expected_head: line.expected_head, shown: { event_type: "transfer", category_id: nil } } ] }).call }
    end
    assert_equal "Restore Family support in Budget, then save this answer.", error.message
    assert_empty domain.heads.where(financial_source_event: line.event)
    assert_empty @household.household_transactions
  end

  test "a different person payment still requires ownership instead of accepting a spending guess" do
    earlier = source([ movement(-3500).merge(merchant: "Zelle to Lina Talun") ])
    identity = link(earlier, tracked: @identity.source_tracked_account)
    approve(stage(earlier[:events].sole, identity: identity, amount: -3500, merchant: "Zelle to Lina Talun"))
    payment = source([ movement(-3500).merge(merchant: "Zelle to Lina Talun") ])
    link(payment, tracked: @identity.source_tracked_account)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    assert_equal :person_payment_duplicate, line.kind
    input = { lines: [ { event_id: line.event.id, decision: "own_account", expected_head: line.expected_head, shown: { event_type: "purchase", category_id: line.category_id } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    version = domain.heads.find_by!(financial_source_event: line.event).approved_version
    assert_equal "transfer", version.event_type
    assert_equal "distinct", version.overlap_disposition
    assert_empty @household.household_transactions
  end

  test "own account keeps a reviewed card payment as a card payment" do
    payment = source([ movement(-1500, type: "debt_payment").merge(merchant: "Payment to Talun card") ])
    link(payment)
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    assert_equal :card_payment, line.kind
    input = { lines: [ { event_id: line.event.id, decision: "as_read", expected_head: line.expected_head, shown: { event_type: "debt_payment", category_id: nil } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    assert_equal "debt_payment", domain.heads.find_by!(financial_source_event: line.event).approved_version.event_type
    assert_empty @household.household_transactions
  end

  test "a person payment with unread direction can explicitly choose family support in the line form" do
    payment = source([ movement(nil, type: "unknown").merge(merchant: "Zelle to Lina Talun", limitations: [ "transaction_direction_unclear" ], source_amount_text: "15.00") ])
    link(payment)
    event = payment[:events].sole
    presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, payment[:revision], user: @user).context(event_ids: [ event.id ])
    assert presenter[:plan][:attention].sole[:recipient_question]
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    input = { lines: [ { event_id: event.id, decision: "edited", expected_head: line.expected_head,
      edit: { kind: "spending", money_direction: "out", amount_cents: 1500, category_id: nil } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    version = domain.heads.find_by!(financial_source_event: event).approved_version
    assert_equal "Family support", version.budget_category.name
    assert_equal "sent-to-someone:#{event.id}", version.external_reference
    assert_equal 1500, @household.household_transactions.sole.total_amount_cents
  end

  test "platform fees and cash withdrawals keep their existing spending questions" do
    %w[fee cash_withdrawal].each do |type|
      payment = source([ movement(-1500, type: type).merge(merchant: "Cash App #{type == 'fee' ? 'service fee' : 'ATM withdrawal'}") ])
      link(payment)
      event = payment[:events].sole
      refute FinancialDocuments::SourceReview::TransferPairs.person_wording?(event, FinancialDocuments::SourceReview::ParticipantPlan.merchant_for(event))
      line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
      refute_includes [ :person_payment, :person_payment_duplicate ], line.kind
    end
  end

  test "an older approved uncategorized person payment keeps its category question" do
    payment = source([ movement(-3500).merge(merchant: "Zelle to Lina Talun") ])
    identity = link(payment)
    event = payment[:events].sole
    approve(stage(event, identity: identity, amount: -3500, merchant: "Zelle to Lina Talun", category: nil))
    row = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, payment[:revision], user: @user).context(event_ids: [ event.id ])[:plan][:attention].sole
    assert_equal :no_category, row[:kind]
    assert_equal false, row[:recipient_question]
    assert_empty @household.household_transactions
  end

  test "person payments require an answer and someone else is protected spending" do
    @household.budget_categories.create!(name: "family support", stack_key: "discretionary")
    payment = source([ movement(-3500, type: "transfer").merge(merchant: "Zelle Payment to Lina Talun") ])
    link(payment)
    evidence = payment[:events].sole.financial_source_evidence
    evidence.update!(payload: evidence.payload.merge("merchant" => "Lina Talun", "raw_description" => "Zelle to Lina Talun"))
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    line = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).lines.sole
    assert_equal :person_payment, line.kind
    assert_empty FinancialDocuments::SourceReview::ParticipantPlan.new(@household, payment[:revision]).ready_ids
    input = { lines: [ { event_id: line.event.id, decision: "someone_else", expected_head: line.expected_head, shown: { event_type: "transfer", category_id: nil } } ] }
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, payment[:revision], input).call }
    actual = @household.household_transactions.sole
    assert_equal 3500, actual.total_amount_cents
    version = domain.heads.find_by!(financial_source_event: line.event).approved_version
    assert_equal "sent-to-someone:#{line.event.id}", version.external_reference
    assert_equal "family support", version.budget_category.name
    assert SpendingPatterns::Analyzer.protected_category?(version.budget_category.name)
  end

  test "overlap preload survives references undated facts and counterpart invalidation" do
    page = source((1..22).map { |i| movement(-1000 - i, row: i) })
    identity = link(page)
    copy = source([ movement(-1001) ])
    copy_identity = link(copy)
    approved = approve(stage(copy[:events].sole, identity: copy_identity, amount: -1001))
    context = FinancialDocuments::SourceReview::OverlapDetector::Context.new(@household, excluded_revision_id: page[:revision].id)
    context.preload!(page[:events], page[:import].checksum_sha256)
    facts = FinancialDocuments::SourceReview::ParticipantPlan.facts_as_read(page[:events].first, identity_id: identity.id, merchant: "Synthetic merchant", category_id: @category.id)
    [ "own-account:1", "sent-to-someone:2", "overlap-cleared:3", "unpaired-transfer:4", nil ].each do |reference|
      changed = facts.merge(external_reference: reference)
      changed = changed.merge(posted_on: nil) unless reference
      detector = FinancialDocuments::SourceReview::OverlapDetector
      assert_equal detector.new(@household, page[:events].first, changed).call,
        detector.new(@household, page[:events].first, changed, context: context).call
    end
    context.invalidate_event!(copy[:events].sole)
    queries = []
    ActiveSupport::Notifications.subscribed(->(*args) { queries << args.last[:sql] unless args.last[:name] == "SCHEMA" }, "sql.active_record") do
      page[:events].each do |event|
        context.candidates(facts.merge(signed_amount_cents: event.signed_amount_cents), page[:import].checksum_sha256, event.locator)
      end
    end
    puts "MIXED_PRELOAD ordinary_followup_queries=#{queries.length}"
    assert_empty queries, "Special answers must not turn off the preload for the rest of the page"
    assert_equal approved.id, context.heads.fetch(copy[:events].sole.id).approved_version_id
  end

  test "large household statement save has bounded plan preparation and history reads" do
    template = approve(stage(@source[:events].sole))
    4.times do |account_number|
      12.times do |month|
        history = source((1..34).map { |i| movement(-10_000 - account_number * 1000 - i, row: i) }, period: "2026-%02d" % (month + 1))
        identity = link(history)
        history[:events].each do |event|
          head = SourceReviewHead.create!(household: @household, financial_source_event: event)
          attributes = template.attributes.except("id").merge("source_review_head_id" => head.id, "source_account_identity_version_id" => identity.id,
            "signed_amount_cents" => event.signed_amount_cents, "purchase_amount_cents" => event.signed_amount_cents.abs,
            "posted_on" => event.posted_on, "digest" => SecureRandom.hex(32))
          version = SourceReviewVersion.create!(attributes)
          head.update!(approved_version: version)
        end
      end
    end
    assert_operator SourceReviewHead.where(household: @household).count, :>=, 1500
    HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).ensure_plan!
    [ 1, 22, 50, 100 ].each do |size|
      fresh = source((1..size).map { |i| movement(-50_000 - i, row: i) })
      link(fresh)
      entries = fresh[:events].map { |event| { event_id: event.id, decision: "edited", edit: { kind: "spending", category_id: @category.id } } }
      queries = []
      callers = Hash.new(0)
      elapsed = Benchmark.realtime do
        ActiveSupport::Notifications.subscribed(->(*args) { payload = args.last; queries << payload[:sql] unless payload[:name] == "SCHEMA"; callers[[ payload[:sql], caller.find { |loc| loc.include?("/app/") } ]] += 1 }, "sql.active_record") do
          @household.with_lock do
            domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
            result = FinancialDocuments::SourceReview::LineApprover.new(domain, fresh[:revision], { lines: entries }).call
            assert_equal size, result[:approved]
          end
        end
      end
      File.write("/tmp/hcfo-query-profile-#{size}.txt", callers.sort_by { |_, n| -n }.map { |(sql, loc), n| "#{n} #{loc} #{sql}" }.join("\n")) if ENV["PROFILE_SAVE"]
      puts "STATEMENT_SAVE size=#{size} seconds=#{elapsed.round(3)} queries=#{queries.length} queries_per_line=#{(queries.length.to_f / size).round(2)} estimated_production_seconds=#{(queries.length * 0.01).round(2)}"
      assert_equal size, @household.household_transactions.where(financial_source_event_id: fresh[:events].map(&:id)).count
      unless ENV["STATEMENT_SAVE_BASELINE"]
        assert_operator queries.length, :<=, { 1 => 100, 22 => 300, 50 => 600, 100 => 1125 }.fetch(size)
        refute queries.any? { |sql| sql.include?('SELECT "financial_source_events".*') && sql.include?("DISTINCT ON") && !sql.include?('"signed_amount_cents"') }, "Overlap checks must narrow the household history"
        assert_operator queries.count { |sql| sql.include?('FROM "budget_allocations"') }, :<=, 12
      end
    end
  end

  test "bulk category snapshots follow category changes made while provisioning the first projection" do
    @household.expense_items.create!(label: @category.name, stack_key: "discretionary", amount_cents: 5000, cadence: "monthly")
    fresh = source([ movement(-1700), movement(-1800, row: 2) ])
    link(fresh)
    entries = fresh[:events].map { |event| { event_id: event.id, decision: "edited", edit: { kind: "spending", category_id: @category.id } } }
    @household.with_lock do
      domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
      result = FinancialDocuments::SourceReview::LineApprover.new(domain, fresh[:revision], { lines: entries }).call
      assert_equal 2, result[:approved]
    end
    versions = SourceReviewVersion.joins(:source_review_head).where(source_review_heads: { financial_source_event_id: fresh[:events].map(&:id) }).order(:id)
    assert_equal %w[non_discretionary discretionary], versions.map { |version| version.category_snapshot.fetch("stack_key") }
    assert_equal [ 1700, 1800 ], @household.household_transactions.where(financial_source_event_id: fresh[:events].map(&:id)).order(:id).pluck(:total_amount_cents)
  end

  test "bulk corrections invalidate the coverage of aliases just like separate approvals" do
    @source = source([ movement(-1000), movement(-1100, row: 2) ])
    @identity = link(@source)
    copies = @source[:events].map do |event|
      original = approve(stage(event, amount: event.signed_amount_cents))
      copy = source([ movement(event.signed_amount_cents) ])
      identity = link(copy, tracked: @identity.source_tracked_account)
      approve(stage(copy[:events].sole, identity: identity, amount: event.signed_amount_cents, disposition: "match", overlap: "match", matched_version_id: original.id))
      copy[:import].update!(metadata: copy[:import].metadata.merge("source_accounting_review_pending" => false))
      copy
    end
    event = @source[:events].first
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, @source[:revision])
    entry = { event_id: event.id, decision: "edited", edit: { kind: "spending", amount_cents: 900, category_id: @category.id }, expected_head: plan.line_for(event.id).expected_head }
    @household.with_lock do
      domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
      result = FinancialDocuments::SourceReview::LineApprover.new(domain, @source[:revision], { lines: [ entry ] }).call
      assert_equal 1, result[:approved]
    end
    assert_equal [ true, false ], copies.map { |copy| copy[:import].reload.metadata.fetch("source_accounting_review_pending") }
  end

  test "bulk coverage includes an account with no lines" do
    account = @source[:revision].financial_source_accounts.sole.dup
    account.assign_attributes(source_key: "empty-savings", opening_balance_cents: 0, closing_balance_cents: 0, printed_debit_cents: 0, printed_credit_cents: 0, printed_row_count: 0)
    account.save!
    raw = account_input_without_lookup(account)
    run_operation(OPS::AccountLink, raw)
    result = bulk_save(@source, [ edit_entry(@source[:events].sole) ], coverage_answer: "nothing_missing", expected_coverage_id: nil)
    assert result[:complete]
    assert_equal "complete", SourceRevisionApproval.where(financial_extraction_revision: @source[:revision]).last.coverage_status
  end

  test "bulk validates an earlier stale line before a later invalid edit" do
    fresh = source([ movement(-1700), movement(-1800, row: 2) ])
    identity = link(fresh)
    approve(stage(fresh[:events].first, identity: identity, amount: -1700))
    first, second = fresh[:events]
    error = assert_raises(FinancialDocuments::SourceReview::Domain::StaleReview) do
      bulk_save(fresh, [ edit_entry(first).tap { |entry| entry[:expected_head][:approved_version_id] = nil; entry[:edit][:amount_cents] = 1699 }, { event_id: second.id, decision: "edited", edit: { kind: "invalid" } } ])
    end
    assert_match "another window", error.message
  end

  test "bulk uses page candidate scope when the statement has no checksum" do
    fresh = source([ movement(-1763), movement(-1763, row: 2) ], checksum: nil)
    link(fresh)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    refute plan.lines.any? { |line| line.kind == :duplicate }
    result = bulk_save(fresh, fresh[:events].map { |event| edit_entry(event) })
    assert_equal 2, result[:approved]
  end

  test "round four no checksum page ignores siblings when an excluded external row activates preload" do
    external = source([ movement(-1763) ])
    identity = link(external)
    approve(stage(external[:events].sole, identity: identity, amount: -1763, disposition: "exclude", overlap: "excluded"))
    fresh = source([ movement(-1763), movement(-1763, row: 2) ], checksum: nil)
    link(fresh)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision])
    assert_empty plan.lines.flat_map(&:overlaps)
    result = bulk_save(fresh, fresh[:events].map { |event| edit_entry(event) })
    assert_equal 2, result[:approved]
  end

  test "bulk refuses the same line twice before voiding its spending" do
    event = @source[:events].sole
    version = approve(stage(event))
    project(version)
    error = assert_raises(ArgumentError) do
      bulk_save(@source, [ { event_id: event.id, decision: "leave_out" }, edit_entry(event) ])
    end
    assert_match "only once", error.message
    assert_equal "confirmed", @household.household_transactions.where(financial_source_event: event).sole.status
  end

  test "a counterpart approval refreshes heads sequence actuals and overlap state inside a batch" do
    fresh = source([ movement(-1700), movement(-1800, row: 2) ])
    link(fresh)
    @household.with_lock do
      domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
      domain.overlap_context = FinancialDocuments::SourceReview::OverlapDetector::Context.new(@household)
      plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, fresh[:revision], overlap_context: domain.overlap_context)
      domain.begin_line_batch!(plan.lines.map(&:event), revision: fresh[:revision], plan: plan)
      worker = FinancialDocuments::SourceReview::LineApprover.new(domain, fresh[:revision], {})
      event = fresh[:events].last
      facts = worker.send(:facts_for, plan.line_for(event.id), "edited", { kind: "spending", category_id: @category.id }, domain.overlap_context.accounts[event.financial_source_account_id].approved_version_id)
      worker.send(:stage_and_approve!, event, domain.line_head(event), facts)
      first = domain.line_head(event).approved_version
      assert_equal 1, domain.actuals_for(event).length
      # A second domain instance models a counterpart writer using ordinary
      # operations in this same locked request. Explicitly invalidate its event.
      external = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
      other_worker = FinancialDocuments::SourceReview::LineApprover.new(external, fresh[:revision], {})
      other_worker.send(:stage_and_approve!, event, external.line_head(event), facts)
      domain.record_write!(event)
      assert_equal 2, domain.line_head(event).approved_version.version_number
      assert_equal 1, domain.actuals_for(event).length
      worker.send(:stage_and_approve!, event, domain.line_head(event), facts.merge(disposition: "exclude", purchase_amount_cents: nil, budget_category_id: nil, overlap_disposition: "excluded"))
      assert_equal 3, domain.line_head(event).approved_version.version_number
      assert_empty domain.actuals_for(event)
      assert_equal first.id, domain.line_head(event).approved_version.supersedes.supersedes_id
    ensure
      domain.end_line_batch!
    end
  end

  test "coverage preserves metadata written after the import was loaded" do
    approve(stage(@source[:events].sole))
    revision = @source[:revision]
    stale_import = revision.financial_document_import
    FinancialDocumentImport.find(stale_import.id).update!(metadata: stale_import.metadata.merge("counterpart_note" => "keep this"))
    state = FinancialDocuments::SourceReview::ApprovalState.new(@household, revision).call
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    raw = { revision_id: revision.id, requested_status: "complete", expected_digest: state[:content_digest], reason: "Verified synthetic coverage",
      coverage_attestation: { all_document_rows_accounted: true, accounts: [ { source_account_id: @source[:events].sole.financial_source_account_id,
        identity_version_id: @identity.id, period_start_on: "2026-07-01", period_end_on: "2026-07-31", all_rows_accounted: true } ] } }
    input = domain.normalize("revision_approve", raw)
    @household.with_lock { FinancialDocuments::SourceReview::RevisionApprover.new(domain, revision, input).call }
    assert_equal "keep this", stale_import.reload.metadata["counterpart_note"]
  end

  def bulk_save(source, entries, **extra)
    @household.with_lock do
      domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
      FinancialDocuments::SourceReview::LineApprover.new(domain, source[:revision], { lines: entries }.merge(extra)).call
    end
  end

  def edit_entry(event)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, event.financial_extraction_revision)
    { event_id: event.id, decision: "edited", expected_head: plan.line_for(event.id).expected_head, edit: { kind: "spending", category_id: @category.id } }
  end

  def account_input_without_lookup(account)
    { source_account_id: account.id, account_basis: "asset", label: "Synthetic savings", base_version_id: nil, base_lock_version: 0,
      statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Verified empty account" }
  end

  test "final rebase both legs on one page are approved once in one request" do
    page = source([ movement(-2900, type: "transfer"), movement(2900, row: 2, type: "transfer").merge(account_key: "savings") ],
      extra_accounts: [ { account_key: "savings", account_basis: "asset" } ])
    page[:revision].financial_source_accounts.each do |account|
      run_operation(OPS::AccountLink, { source_account_id: account.id, account_basis: "asset", label: "Fictional #{account.id}", base_version_id: nil, base_lock_version: 0, statement_facts: {}, reason: "Verified fictional account" })
    end
    save_final_page(page) { |line| pair_answer(line) }
    assert_equal [ 1, 1 ], SourceReviewHead.where(financial_source_event_id: page[:events].map(&:id)).map { |head| head.approved_version.version_number }
    group = FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(page[:events].first)
    assert_equal 2, group.source_economic_memberships.count
    assert_empty @household.household_transactions
  end

  test "final rebase pairs two legs and unpairs with increasing counterpart versions" do
    debit = source([ movement(-2500, type: "transfer") ])
    credit = source([ movement(2500, type: "transfer") ])
    link(debit)
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Fictional savings 4412"))
    save_final_page(debit) { |line| pair_answer(line) }
    versions = SourceReviewHead.where(financial_source_event_id: [ debit[:events].sole.id, credit[:events].sole.id ]).map(&:approved_version)
    assert_equal [ 1, 1 ], versions.map(&:version_number)
    assert FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(debit[:events].sole)
    save_final_page(debit) { |line| { decision: "unpair_transfer" } }
    versions.each do |previous|
      current = previous.source_review_head.reload.approved_version
      assert_equal 2, current.version_number
      assert_equal previous.id, current.supersedes_id
    end
    assert_nil FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(debit[:events].sole)
    assert_empty @household.household_transactions
  end

  test "final rebase mixed 22 line batch preserves pairing person answers and cash release totals" do
    withdrawal = source([ movement(-10_000, type: "cash_withdrawal") ])
    identity = link(withdrawal)
    approve(stage(withdrawal[:events].sole, identity: identity, amount: -10_000, event_type: "cash_withdrawal", projection: { action: "create" }))
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: 2026).current_period_for(Date.new(2026, 7, 7))
    purchase = @household.household_transactions.create!(budget_period: period, occurred_on: "2026-07-07", merchant: "Fictional Market", total_amount_cents: 3200, source_type: "manual_chat", status: "confirmed",
      metadata: { "cash_withdrawal" => { "financial_source_event_id" => withdrawal[:events].sole.id, "amount_cents" => 3200, "withdrawn_on" => "2026-07-07" } })
    purchase.transaction_splits.create!(budget_category: @category, amount_cents: 3200)
    @household.transaction_drafts.create!(occurred_on: purchase.occurred_on, merchant: purchase.merchant, total_amount_cents: 3200, source_type: "manual_chat", status: "confirmed", confirmed_transaction: purchase,
      draft_payload: { "cash_payment" => HouseholdFinance::CashPayment.participant_payload })
    initial = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).plan_data
    assert_equal 10_000, initial.fetch(:rows).sum { |row| HouseholdFinance::Money.cents(row.fetch(:months)[6].fetch(:actual)) }
    credit = source([ movement(2500, type: "transfer") ])
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Fictional savings 4412"))
    rows = [ movement(-2500, type: "transfer"), movement(-3500, row: 2).merge(merchant: "Zelle to Lina Talun"),
      movement(-1700, row: 3).merge(merchant: "Venmo to Ana Cruz"), movement(-3200, row: 4).merge(merchant: "Fictional Market") ]
    old_credit = source([ movement(2600, type: "transfer") ])
    run_operation(OPS::AccountLink, account_input(old_credit).merge(label: "Fictional savings 5523"))
    rows << movement(-2600, type: "transfer", row: 5)
    rows += (6..22).map { |i| movement(-100 - i, row: i).merge(merchant: "Fictional shop #{i}") }
    page = source(rows)
    link(page)
    # A reviewed-out copy triggers the shared overlap pool without asking a
    # different question or changing any of this page's financial outcomes.
    history = source([ movement(-106) ])
    history_identity = link(history)
    approve(stage(history[:events].sole, identity: history_identity, amount: -106, disposition: "exclude", overlap: "excluded", purchase: nil, category: nil))
    save_final_page(page, only: [ page[:events][4].id ]) { |line| pair_answer(line) }
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| queries << args.last[:sql] unless args.last[:name] == "SCHEMA" }
    save_final_page(page) do |line|
      case page[:events].index { |event| event.id == line.event.id }
      when 0 then pair_answer(line)
      when 1 then { decision: "someone_else" }
      when 2 then { decision: "own_account" }
      when 3 then { decision: "same_purchase", match_transaction_id: purchase.id }
      when 4 then { decision: "unpair_transfer" }
      else { decision: "edited", edit: { kind: "spending", category_id: @category.id } }
      end
    end
    ActiveSupport::Notifications.unsubscribe(subscriber)
    puts "MIXED_STATEMENT_SAVE queries=#{queries.length}"
    assert_operator queries.length, :<=, 740 unless ENV["STATEMENT_SAVE_BASELINE"]
    heads = SourceReviewHead.where(financial_source_event_id: page[:events].map(&:id)).includes(:approved_version).index_by(&:financial_source_event_id)
    page[:events].each_with_index { |event, i| assert_equal(i == 4 ? 2 : 1, heads.fetch(event.id).approved_version.version_number) }
    assert_nil FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(page[:events][4])
    assert_equal "transfer", heads.fetch(page[:events][2].id).approved_version.event_type
    assert_equal "Family support", heads.fetch(page[:events][1].id).approved_version.budget_category.name
    assert_equal purchase.id, heads.fetch(page[:events][3].id).approved_version.matched_transaction_id
    assert FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(page[:events].first)
    assert_nil purchase.reload.metadata[HouseholdFinance::CashDrawdowns::LINK_KEY]
    assert_equal 1, @household.household_audit_events.where(event_type: "cash_purchase.paid_by_card").count
    drawdowns = HouseholdFinance::CashDrawdowns.new(@household)
    assert_empty drawdowns.call
    assert_equal 10_000, drawdowns.candidates(on: Date.new(2026, 7, 7)).sole.available_cents
    expected = 10_000 + 3500 + 3200 + (6..22).sum { |i| 100 + i }
    plan = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).plan_data
    assert_equal expected, plan.fetch(:rows).sum { |row| HouseholdFinance::Money.cents(row.fetch(:months)[6].fetch(:actual)) }
    assert_equal expected, @household.household_transactions.where(status: "confirmed").sum(:total_amount_cents)
    save_final_page(page, only: [ page[:events].first.id ]) { |_line| { decision: "unpair_transfer" } }
    assert_nil FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(page[:events].first)
    assert_equal expected, @household.household_transactions.where(status: "confirmed").sum(:total_amount_cents)
  end

  test "round four pairing leaves unrelated alias coverage untouched" do
    page = source([ movement(-5000, type: "transfer"), movement(-1300, row: 2) ])
    identity = link(page)
    original = approve(stage(page[:events].last, identity: identity, amount: -1300))
    copy = source([ movement(-1300) ])
    copy_identity = link(copy, tracked: identity.source_tracked_account)
    approve(stage(copy[:events].sole, identity: copy_identity, amount: -1300, disposition: "match", overlap: "match", matched_version_id: original.id))
    credit = source([ movement(5000, type: "transfer") ])
    run_operation(OPS::AccountLink, account_input(credit).merge(label: "Fictional savings"))
    copy[:import].update!(metadata: copy[:import].metadata.merge("source_accounting_review_pending" => false))
    save_final_page(page, only: [ page[:events].first.id ]) { |line| pair_answer(line) }
    assert FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(page[:events].first)
    assert_equal false, copy[:import].reload.metadata.fetch("source_accounting_review_pending")
  end

  test "round four unpair retains the outside counterpart old alias dependencies" do
    debit = source([ movement(-5000, type: "transfer") ])
    link(debit)
    credit = source([ movement(5000, type: "transfer") ])
    identity = run_operation(OPS::AccountLink, account_input(credit).merge(label: "Fictional savings"))
    save_final_page(debit) { |line| pair_answer(line) }
    original = SourceReviewHead.find_by!(financial_source_event: credit[:events].sole).approved_version
    copy = source([ movement(5000, type: "transfer") ])
    copy_identity = link(copy, tracked: identity.source_tracked_account)
    approve(stage(copy[:events].sole, identity: copy_identity, amount: 5000, purchase: nil, event_type: "transfer", category: nil, disposition: "match", overlap: "match", matched_version_id: original.id))
    copy[:import].update!(metadata: copy[:import].metadata.merge("source_accounting_review_pending" => false))
    save_final_page(debit) { |_line| { decision: "unpair_transfer" } }
    assert_nil FinancialDocuments::SourceReview::TransferPairs.new(@household).paired(debit[:events].sole)
    assert_equal true, copy[:import].reload.metadata.fetch("source_accounting_review_pending")
  end

  test "round four counterpart approval checks copies outside page amounts" do
    debit = source([ movement(-50_000, type: "transfer"), movement(-1200, row: 2) ])
    link(debit)
    credit = source([ movement(50_000, type: "transfer") ])
    identity = run_operation(OPS::AccountLink, account_input(credit).merge(label: "Fictional savings"))
    copy = source([ movement(50_000, type: "transfer") ])
    copy_identity = link(copy, tracked: identity.source_tracked_account)
    stage(copy[:events].sole, identity: copy_identity, amount: 50_000, purchase: nil, event_type: "transfer", category: nil)
    # A separate purchase copy makes the page build a narrowed preload for
    # -1200, while the counterpart's +50000 stays outside that candidate set.
    purchase_copy = source([ movement(-1200) ])
    link(purchase_copy)
    error = assert_raises(ArgumentError) { save_final_page(debit, only: [ debit[:events].first.id ]) { |line| pair_answer(line) } }
    assert_includes error.message, "These rows may overlap"
    assert_nil SourceReviewHead.find_by(financial_source_event: debit[:events].first)&.approved_version_id
    assert_nil SourceReviewHead.find_by(financial_source_event: credit[:events].sole)&.approved_version_id
  end

  test "round four new Family support gets allocations after earlier projection" do
    page = source([ movement(-1300), movement(-3500, row: 2).merge(merchant: "Zelle to Lina Talun") ])
    link(page)
    save_final_page(page) do |line|
      line.event.id == page[:events].first.id ? { decision: "edited", edit: { kind: "spending", category_id: @category.id } } : { decision: "someone_else" }
    end
    category = @household.budget_categories.find_by!(name: "Family support")
    allocations = BudgetAllocation.where(budget_category: category)
    assert_equal 12, allocations.count
    assert_equal [ 0 ], allocations.distinct.pluck(:planned_amount_cents)
    assert_equal 4800, @household.household_transactions.where(status: "confirmed").sum(:total_amount_cents)
  end

  def pair_answer(line)
    pair = line.pair
    { decision: "pair_transfer", transfer_pair: { event_id: pair[:event].id, approved_version_id: pair[:version]&.id, account_version_id: pair[:identity].id } }
  end

  def save_final_page(src, only: nil)
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, src[:revision])
    entries = plan.lines.select { |line| !only || only.include?(line.event.id) }.map do |line|
      { event_id: line.event.id, expected_head: line.expected_head, shown: { event_type: line.saved&.event_type || line.event.event_type, category_id: line.category_id } }.merge(yield(line))
    end
    domain = FinancialDocuments::SourceReview::Domain.new(@household, user: @user)
    @household.with_lock { FinancialDocuments::SourceReview::LineApprover.new(domain, src[:revision], { lines: entries }).call }
  end

  private

  def run_operation(klass, input)
    operation = klass.new(@household, user: @user)
    prepared = operation.prepare(input)
    ApplicationRecord.transaction do
      result = operation.execute!(prepared, source: "manual")
      operation.send(:verify_after!, prepared.predicted_after_snapshot, operation.after_snapshot(result, prepared))
      result
    end
  end

  def movement(amount, row: 1, type: "purchase", posted_on: "2026-07-07")
    { account_key: "synthetic-account", row_kind: "posted", event_type: type, signed_amount_cents: amount, posted_on: posted_on, merchant: "Synthetic merchant", locator: { page: 1, row: row } }
  end

  def source(rows, checksum: SecureRandom.hex(32), period: "2026-07", coverage: {}, extra_accounts: [], basis: "asset", from: nil, to: nil)
    import = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.pdf", content_type: "application/pdf", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.pdf", checksum_sha256: checksum)
    attempt = import.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    rows = rows.map { |row| row.merge(posted_on: period + "-07") } if period != "2026-07"
    amounts_known = rows.none? { |row| row[:signed_amount_cents].nil? }
    net = rows.sum { |row| row[:signed_amount_cents] } if amounts_known
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "synthetic-account", account_basis: basis, period_start_on: from || period + "-01", period_end_on: to || Date.iso8601(period + "-01").end_of_month.iso8601, opening_balance_cents: 20_000, closing_balance_cents: net && 20_000 + net,
        printed_debit_cents: amounts_known ? rows.sum { |row| [ -row[:signed_amount_cents], 0 ].max } : nil, printed_credit_cents: amounts_known ? rows.sum { |row| [ row[:signed_amount_cents], 0 ].max } : nil, printed_row_count: rows.length } ] + extra_accounts, events: rows, reported_row_count: rows.length }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] }.merge(coverage))
    result = FinancialDocuments::SourceAccountingPersister.new(import, attempt: attempt, accounting: accounting).call
    import.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: import)
  end

  def account_input(source)
    account = source[:revision].financial_source_accounts.sole
    { source_account_id: account.id, account_basis: account.account_basis == "liability" ? "liability" : "asset", label: account.account_basis == "liability" ? "Synthetic card" : "Synthetic checking", base_version_id: nil, base_lock_version: 0,
      statement_facts: account.attributes.slice("period_start_on", "period_end_on", "opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents", "printed_row_count"), reason: "Participant verified synthetic account and header" }
  end

  def link(source, tracked: nil)
    run_operation(OPS::AccountLink, account_input(source).merge(tracked_account_id: tracked&.id))
  end

  def stage(event, identity: @identity, amount: -1_000, purchase: :default, posted_on: "2026-07-07", event_type: "purchase", disposition: "include", overlap: "new", matched_version_id: nil, reason: "Participant reviewed the synthetic row", projection: { action: "none" }, merchant: nil, category: @category, external_reference: nil)
    head = SourceReviewHead.find_by(household: @household, financial_source_event: event)
    purchase = amount&.abs if purchase == :default
    pending = head&.source_review_drafts&.pending&.first
    run_operation(OPS::DraftStage, { event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0, expected_pending_draft: pending && { id: pending.id, lock_version: pending.lock_version, digest: pending.digest }, reason: reason, projection: projection,
      facts: { source_account_identity_version_id: identity.id, disposition: disposition, event_type: event_type, signed_amount_cents: amount, purchase_amount_cents: purchase, posted_on: posted_on,
        merchant: merchant || FinancialDocuments::SourceReview::ParticipantPlan.merchant_for(event), external_reference: external_reference, budget_category_id: category&.id, overlap_disposition: overlap, matched_version_id: matched_version_id } })
  end

  def draft_input(draft)
    draft.reload
    { draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest }
  end

  def approve(draft) = run_operation(OPS::DraftApprove, draft_input(draft))
  def reader = FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: [ @source[:revision].id ])
  def group_input(kind, members) = { kind: kind, members: members, base_version_id: nil, base_lock_version: 0, reason: "Participant explicitly verified the synthetic economic link" }

  def project(version)
    run_operation(OPS::ExpenseProject, version_id: version.id, expected_version_digest: version.digest, projection: { action: "create" }, reason: "Participant separately approved positive spending")
  end

  def attest(status, src = @source)
    state = FinancialDocuments::SourceReview::ApprovalState.new(@household, src[:revision]).call
    identity = SourceAccountReviewHead.find_by!(financial_source_account: src[:revision].financial_source_accounts.sole).approved_version
    run_operation(OPS::RevisionApprove, revision_id: src[:revision].id, expected_digest: state[:content_digest], requested_status: status, reason: "Participant declared reviewed coverage and limitations",
      coverage_attestation: { all_document_rows_accounted: true, accounts: [ { source_account_id: identity.source_account_review_head.financial_source_account_id, identity_version_id: identity.id,
        period_start_on: identity.statement_facts["period_start_on"], period_end_on: identity.statement_facts["period_end_on"], all_rows_accounted: true } ] })
  end
end
