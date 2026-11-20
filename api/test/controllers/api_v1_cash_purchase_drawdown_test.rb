require "test_helper"

# Cash counts when it is withdrawn (decision 3, 2026-11-19). A purchase she paid in cash names part of that cash and
# adds nothing: "Paid with the $100 you took out on Aug 3?" Yes moves its amount out of Cash into its own category, in
# the month the cash was taken out. No counts it as its own purchase. Nothing is linked for her.
class ApiV1CashPurchaseDrawdownTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(clerk_id: "cash-#{SecureRandom.hex(8)}", email: "cash-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @cash = @household.budget_categories.create!(name: "Cash", stack_key: "discretionary", sort_order: 1)
    @dining = @household.budget_categories.create!(name: "Dining", stack_key: "discretionary", sort_order: 2)
    @groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 3)
  end

  test "a $100 withdrawal plus a $40 cash lunch is $100 of spending, with $40 of it named" do
    withdrawal = withdraw(10_000, "2026-08-03")
    assert_equal 10_000, budget_actual(@cash, month: 8)
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)

    card = draft.fetch("cash_payment")
    assert_equal [ "participant", 4000 ], card.values_at("source", "cash_cents")
    assert_equal "Paid with the $100 you took out on Aug 3?", card.fetch("question")
    assert_equal [ [ withdrawal.id, "2026-08-03", 10_000, 10_000, 4000 ] ],
      card.fetch("candidates").map { |row| row.values_at("financial_source_event_id", "withdrawn_on", "amount_cents", "available_cents", "covers_cents") }

    # Confirm alone can't count it: the cash already counted.
    confirm(draft)
    assert_response :conflict
    assert_equal "cash_withdrawal_question", response.parsed_body.fetch("code")
    assert_equal "Paid with the $100 you took out on Aug 3? Choose on the purchase. Nothing was added to your spending.", response.parsed_body.fetch("errors").sole
    assert_equal "pending", TransactionDraft.find(draft.fetch("id")).status
    assert_equal 10_000, month_total(8)

    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_equal "Saved Tasi Demo Cafe for $40 in Dining, paid with cash you took out on Aug 3. That cash already counted, so $40 moved from Cash to Dining.",
      @household.chat_sessions.flat_map { |session| session.chat_messages.pluck(:content) }.last
    purchase = TransactionDraft.find(draft.fetch("id")).confirmed_transaction
    assert_equal({ "financial_source_event_id" => withdrawal.id, "amount_cents" => 4000 }, purchase.metadata.fetch("cash_withdrawal").slice("financial_source_event_id", "amount_cents"))

    # Budget, the spending report, Mia's analyzer and Mia's month answer: $100, $40 Dining and $60 Cash.
    assert_equal [ 6000, 4000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ]
    assert_equal 10_000, month_total(8)
    report = spending_report("2026-08-01", "2026-08-31")
    assert_equal 10_000, HouseholdFinance::Money.cents!(report.dig("totals", "actual"))
    assert_equal({ "Cash" => 6000, "Dining" => 4000 }, report.fetch("categories").select { |row| row["actual"].to_f.nonzero? }.to_h { |row| [ row["name"], HouseholdFinance::Money.cents(row["actual"]) ] })
    assert_equal({ "withdrawn_on" => "2026-08-03", "amount" => 40.0 }, report.fetch("transactions").find { |row| row["id"] == purchase.id }.fetch("cash_withdrawal"))
    assert_equal 10_000, analyzer("2026-08-01", "2026-08-31").fetch(:observed_spending_cents)
    assert_equal 10_000, mia_month(8).fetch(:spent_so_far_cents)

    # The card says what happened.
    confirmed_card = HouseholdFinance::CashPayment.presentation(TransactionDraft.find(draft.fetch("id")))
    assert_equal [ true, 4000 ], confirmed_card.values_at(:linked, :linked_cents)

    # Reopening gives the cash back, and confirming again asks again.
    post "/api/v1/transaction_drafts/#{draft.fetch('id')}/reopen", headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success, response.body
    assert_equal [ 10_000, 0 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ]
    assert_equal 10_000, month_total(8)
    confirm(draft)
    assert_response :conflict
    assert_equal "cash_withdrawal_question", response.parsed_body.fetch("code")
  end

  test "No counts it as its own purchase, cash from somewhere else" do
    withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_from_elsewhere: true)
    assert_response :success, response.body
    assert_equal [ 10_000, 4000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ]
    assert_equal 14_000, month_total(8)
    assert_equal 14_000, analyzer("2026-08-01", "2026-08-31").fetch(:observed_spending_cents)
    assert_equal "elsewhere", TransactionDraft.find(draft.fetch("id")).draft_payload.dig("cash_payment", "answer")
    assert_nil TransactionDraft.find(draft.fetch("id")).confirmed_transaction.metadata["cash_withdrawal"]
  end

  test "cash taken out in August and spent in September counts in August" do
    withdrawal = withdraw(10_000, "2026-08-28")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-09-02", @dining, paid_with_cash: true)
    assert_equal "Paid with the $100 you took out on Aug 28?", draft.dig("cash_payment", "question")
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body

    assert_equal [ 6000, 4000, 10_000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    assert_equal [ 0, 0, 0 ], [ budget_actual(@cash, month: 9), budget_actual(@dining, month: 9), month_total(9) ]
    assert_equal 10_000, HouseholdFinance::Money.cents!(spending_report("2026-08-01", "2026-08-31").dig("totals", "actual"))
    assert_equal 0, HouseholdFinance::Money.cents!(spending_report("2026-09-01", "2026-09-30").dig("totals", "actual"))
    assert_equal 10_000, analyzer("2026-08-01", "2026-08-31").fetch(:observed_spending_cents)
    assert_equal 0, analyzer("2026-09-01", "2026-09-30").fetch(:observed_spending_cents).to_i
    assert_equal 10_000, analyzer("2026-08-01", "2026-09-30").fetch(:observed_spending_cents)
    assert_equal [ 10_000, 0 ], [ mia_month(8).fetch(:spent_so_far_cents), mia_month(9).fetch(:spent_so_far_cents) ]
  end

  test "a link never takes more than the withdrawal: what is left is offered, and the rest counts on its own" do
    withdrawal = withdraw(10_000, "2026-08-03")
    first = log_purchase("Tasi Demo Market", 70, "2026-08-04", @groceries, paid_with_cash: true)
    confirm(first, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body

    second = log_purchase("Tasi Demo Cafe", 50, "2026-08-05", @dining, paid_with_cash: true)
    assert_equal "Paid with the $100 you took out on Aug 3 ($30 left)?", second.dig("cash_payment", "question")
    assert_equal [ 3000, 3000 ], second.dig("cash_payment", "candidates").sole.values_at("available_cents", "covers_cents")
    confirm(second, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_includes @household.chat_sessions.flat_map { |session| session.chat_messages.pluck(:content) }.last, "The other $20 counts as new spending."

    assert_equal [ 0, 7000, 5000 ], [ @cash, @groceries, @dining ].map { |category| budget_actual(category, month: 8) }
    assert_equal 12_000, month_total(8)

    # Nothing is left, so a third cash purchase is not asked about and counts on its own.
    third = log_purchase("Tasi Demo Bakery", 10, "2026-08-06", @dining, paid_with_cash: true)
    assert_empty third.dig("cash_payment", "candidates")
    assert_match(/counts as its own purchase/, third.dig("cash_payment", "message"))
    confirm(third)
    assert_response :success, response.body
    assert_equal 13_000, month_total(8)

    # Even a stale answer naming the empty withdrawal is refused.
    fourth = log_purchase("Tasi Demo Bakery", 5, "2026-08-07", @dining, paid_with_cash: true)
    confirm(fourth, cash_withdrawal_event_id: withdrawal.id)
    assert_response :unprocessable_entity
    assert_equal "pending", TransactionDraft.find(fourth.fetch("id")).status
  end

  test "several withdrawals are offered most recent first, and only ones taken out by the purchase date" do
    older = withdraw(6000, "2026-07-20")
    newer = withdraw(10_000, "2026-08-03")
    withdraw(20_000, "2026-08-10")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    card = draft.fetch("cash_payment")
    assert_equal "Which cash paid for this $40?", card.fetch("question")
    assert_equal [ newer.id, older.id ], card.fetch("candidates").pluck("financial_source_event_id")
    assert_equal [ "the $100 you took out on Aug 3", "the $60 you took out on Jul 20" ], card.fetch("candidates").pluck("label")

    confirm(draft, cash_withdrawal_event_id: older.id)
    assert_response :success, response.body
    assert_equal [ 2000, 4000 ], [ budget_actual(@cash, month: 7), budget_actual(@dining, month: 7) ]
    assert_equal [ 30_000, 0 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ], "The August withdrawals keep all their cash"
  end

  test "with no cash withdrawal it counts normally, and a purchase that wasn't cash is never asked" do
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    assert_equal "Paid with cash. No cash you took out by Aug 5 has any left in your approved statements, so this counts as its own purchase.", draft.dig("cash_payment", "message")
    confirm(draft)
    assert_response :success, response.body
    assert_equal 4000, month_total(8)

    withdraw(10_000, "2026-08-03")
    card = log_purchase("Tasi Demo Cafe", 25, "2026-08-06", @dining)
    assert_nil card.fetch("cash_payment")
    confirm(card)
    assert_response :success, response.body
    assert_equal 16_500, month_total(8)
  end

  test "a withdrawal re-reviewed as a transfer gives the purchase back its own spending" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_equal 10_000, month_total(8)

    version = SourceReviewHead.find_by!(financial_source_event: withdrawal).approved_version
    head = version.source_review_head
    approve(@sources.fetch(withdrawal.id), [ { event_id: withdrawal.id, expected_head: { approved_version_id: head.approved_version_id, lock_version: head.lock_version, account_version_id: version.source_account_identity_version_id },
      decision: "edited", edit: { kind: "moved" } } ])
    assert_response :success, response.body
    assert_equal [ 0, 4000, 4000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
  end

  test "Approve all never answers which cash paid for a purchase" do
    withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    post "/api/v1/transaction_drafts/bulk_confirm", params: { transaction_draft_ids: [ draft.fetch("id") ], year: 2026, confirmation: "CONFIRM 1" },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.fetch("errors").join, "Paid with the $100 you took out on Aug 3? Answer that on its card first."
    assert_equal "pending", TransactionDraft.find(draft.fetch("id")).status
  end

  test "she can say on the card that she paid with cash, or that she didn't" do
    withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining)
    patch "/api/v1/transaction_drafts/#{draft.fetch('id')}", params: { transaction_draft: { paid_with_cash: true } }, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success, response.body
    assert_equal "Paid with the $100 you took out on Aug 3?", response.parsed_body.dig("transaction_draft", "cash_payment", "question")
    patch "/api/v1/transaction_drafts/#{draft.fetch('id')}", params: { transaction_draft: { paid_with_cash: false } }, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :success, response.body
    assert_nil response.parsed_body.dig("transaction_draft", "cash_payment")
  end

  # Review fix 1. The card sends one answer each time. Each answer she gives is kept while the next question is
  # asked, so a purchase that gets both questions can be confirmed, and nothing counts until her last answer.
  test "Different purchase, then which cash: each answer is kept and the next question is asked" do
    withdrawal = withdraw(10_000, "2026-08-03")
    earlier = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining)
    confirm(earlier)
    assert_response :success, response.body
    assert_equal 14_000, month_total(8)

    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft)
    assert_response :conflict
    assert_equal "possible_duplicate", response.parsed_body.fetch("code")

    confirm(draft, different_purchase: true)
    assert_response :conflict
    assert_equal "cash_withdrawal_question", response.parsed_body.fetch("code")
    card = response.parsed_body.fetch("transaction_draft")
    assert_equal "pending", card.fetch("status")
    assert_equal [ "rejected" ], card.fetch("matches").pluck("status").uniq, "Her Different purchase is kept"
    assert_equal "Paid with the $100 you took out on Aug 3?", card.dig("cash_payment", "question"), "so the card asks the cash question next"
    assert_equal 14_000, month_total(8), "Nothing counts yet"

    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_equal [ 6000, 8000, 14_000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    assert_equal 2, @household.household_transactions.where(merchant: "Tasi Demo Cafe", status: "confirmed").count
  end

  test "which cash first, then Different purchase: her Yes is kept while Same purchase? is asked" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    assert_equal "Paid with the $100 you took out on Aug 3?", draft.dig("cash_payment", "question")
    # A purchase she logs by hand meanwhile looks like the same one.
    other = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining)
    confirm(other, different_purchase: true)
    assert_response :success, response.body

    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :conflict
    assert_equal "possible_duplicate", response.parsed_body.fetch("code")
    card = response.parsed_body.fetch("transaction_draft")
    assert_equal [ "proposed" ], card.fetch("matches").pluck("status").uniq
    assert_equal [ withdrawal.id, [] ], card.fetch("cash_payment").values_at("chosen_event_id", "candidates"), "Her Yes is kept"
    assert_equal "You said this was paid with the $100 you took out on Aug 3, so it won't add to your spending.", card.dig("cash_payment", "message")
    assert_nil @household.household_transactions.where("metadata ? 'cash_withdrawal'").first
    assert_equal 14_000, month_total(8), "Nothing counts yet"

    confirm(draft, different_purchase: true)
    assert_response :success, response.body
    purchase = TransactionDraft.find(draft.fetch("id")).confirmed_transaction
    assert_equal withdrawal.id, purchase.metadata.dig("cash_withdrawal", "financial_source_event_id")
    assert_equal [ 6000, 8000, 14_000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
  end

  test "a caller that confirms directly, like the scorecard, also has each answer kept" do
    withdrawal = withdraw(10_000, "2026-08-03")
    confirm(log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining))
    record = TransactionDraft.find(log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true).fetch("id"))

    assert HouseholdFinance::TransactionDraftConfirmer.new(record).call.possible_matches.present?
    asked = HouseholdFinance::TransactionDraftConfirmer.new(record.reload, different_purchase: true).call
    assert_equal "Paid with the $100 you took out on Aug 3?", asked.cash_question.fetch(:question)
    assert_equal [ "rejected" ], record.transaction_draft_matches.reload.pluck(:status).uniq
    done = HouseholdFinance::TransactionDraftConfirmer.new(record.reload, cash_withdrawal: withdrawal.id).call
    assert done.success?, done.errors.to_sentence
    assert_equal 14_000, month_total(8)
  end

  test "a kept Yes whose cash is gone by the time she answers Same purchase? is asked again" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    other = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining)
    confirm(other, different_purchase: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_equal "possible_duplicate", response.parsed_body.fetch("code")
    # Meanwhile the withdrawal is re-reviewed as a transfer.
    move_to_transfer(withdrawal)
    assert_empty TransactionDraft.find(draft.fetch("id")).then { |record| HouseholdFinance::CashPayment.presentation(record).fetch(:candidates) }

    confirm(draft, different_purchase: true)
    assert_response :success, response.body
    assert_nil TransactionDraft.find(draft.fetch("id")).confirmed_transaction.metadata["cash_withdrawal"], "That cash is gone, so it counts on its own"
  end

  # Review fix 2. She logs as she goes and uploads statements later: the withdrawal is approved after the cash
  # purchase it paid for. Until she answers, the purchase counts on its own and Review says so.
  test "a cash purchase confirmed before its withdrawal was approved is asked about, and Yes makes it $100" do
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft)
    assert_response :success, response.body
    assert_empty budget_plan.fetch("cash_purchase_questions")

    withdrawal = withdraw(10_000, "2026-08-03")
    assert_equal 14_000, month_total(8), "Not linked for her"
    question = budget_plan.fetch("cash_purchase_questions").sole
    assert_equal [ draft.fetch("id"), "unanswered", "Tasi Demo Cafe", "2026-08-05", 4000, 4000 ],
      question.values_at("transaction_draft_id", "state", "merchant", "occurred_on", "cash_cents", "counting_on_its_own_cents")
    assert_equal "You paid $40 in cash. Right now it counts on its own, on top of the $100 you took out on Aug 3.", question.fetch("message")
    assert_equal "Paid with the $100 you took out on Aug 3?", question.fetch("question")
    assert_equal [ withdrawal.id ], question.fetch("candidates").pluck("financial_source_event_id")
    assert_equal "No, other cash", question.fetch("decline_label")
    get "/api/v1/workspace", headers: headers
    assert_response :success
    assert_equal [ 1, 1 ], response.parsed_body.dig("dashboard", "action_center").values_at("transaction_review_count", "cash_question_count")

    cash_answer(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_equal "Saved: Tasi Demo Cafe for $40 was paid with cash you took out on Aug 3. That cash already counted, so $40 moved from Cash into this purchase's category.", response.parsed_body.fetch("message")
    assert_equal [ 6000, 4000, 10_000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    assert_empty budget_plan.fetch("cash_purchase_questions")
    assert_equal "confirmed", TransactionDraft.find(draft.fetch("id")).status
    assert_equal "cash_purchase.withdrawal_answered", @household.household_audit_events.order(:id).last.event_type

    # Answering again changes nothing.
    cash_answer(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_equal 10_000, month_total(8)
  end

  test "No, other cash keeps both, on purpose, and isn't asked again" do
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft)
    withdraw(10_000, "2026-08-03")
    cash_answer(draft, cash_from_elsewhere: true)
    assert_response :success, response.body
    assert_equal "Saved: Tasi Demo Cafe for $40 was paid with other cash, so it counts as its own purchase.", response.parsed_body.fetch("message")
    assert_equal [ 10_000, 4000, 14_000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    withdraw(5000, "2026-08-04")
    assert_empty budget_plan.fetch("cash_purchase_questions")
  end

  test "a withdrawal that stops counting puts its cash purchase back on her list" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_empty budget_plan.fetch("cash_purchase_questions")

    move_to_transfer(withdrawal)
    assert_equal 4000, month_total(8)
    question = budget_plan.fetch("cash_purchase_questions").sole
    assert_equal [ "dropped", [], "Count it on its own", nil ], question.values_at("state", "candidates", "decline_label", "question")
    assert_equal "You said this was paid with cash you took out on Aug 3, but that withdrawal is no longer in your approved statements. Right now this $40 counts on its own.", question.fetch("message")

    # Another withdrawal she approves can be chosen instead.
    again = withdraw(8000, "2026-08-02", merchant: "Tasi Demo Branch withdrawal")
    question = budget_plan.fetch("cash_purchase_questions").sole
    assert_equal [ "dropped", [ again.id ], "Paid with the $80 you took out on Aug 2 instead?" ], [ question["state"], question.fetch("candidates").pluck("financial_source_event_id"), question["question"] ]
    cash_answer(draft, cash_withdrawal_event_id: again.id)
    assert_response :success, response.body
    assert_equal [ 4000, 4000, 8000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    assert_empty budget_plan.fetch("cash_purchase_questions")
  end

  test "a withdrawal made smaller puts the part it no longer covers back on her list" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)

    version = SourceReviewHead.find_by!(financial_source_event: withdrawal).approved_version
    head = version.source_review_head
    approve(@sources.fetch(withdrawal.id), [ { event_id: withdrawal.id, expected_head: { approved_version_id: head.approved_version_id, lock_version: head.lock_version, account_version_id: version.source_account_identity_version_id },
      decision: "edited", edit: { kind: "cash", amount_cents: 3000, category_id: @cash.id } } ])
    assert_response :success, response.body
    assert_equal [ 0, 4000, 4000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    question = budget_plan.fetch("cash_purchase_questions").sole
    assert_equal [ "short", 3000, 1000, "Count the rest on its own" ], question.values_at("state", "covered_cents", "counting_on_its_own_cents", "decline_label")
    assert_equal "The cash you took out on Aug 3 now covers $30 of this $40. Right now the other $10 counts on its own.", question.fetch("message")

    cash_answer(draft, cash_from_elsewhere: true)
    assert_response :success, response.body
    assert_empty budget_plan.fetch("cash_purchase_questions")
    assert_equal 4000, month_total(8), "The $30 stays named; the other $10 counts on its own, as she said"
    head.reload
    approve(@sources.fetch(withdrawal.id), [ { event_id: withdrawal.id, expected_head: { approved_version_id: head.approved_version_id, lock_version: head.lock_version, account_version_id: version.source_account_identity_version_id },
      decision: "edited", edit: { kind: "cash", amount_cents: 10_000, category_id: @cash.id } } ])
    assert_response :success, response.body
    assert_money_everywhere(11_000)
    assert_equal 3000, TransactionDraft.find(draft.fetch("id")).confirmed_transaction.metadata.dig("cash_withdrawal", "amount_cents")
  end

  test "a cash answer on a purchase that isn't asked about is refused" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining)
    confirm(draft)
    cash_answer(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :conflict
    assert_equal "stale_review", response.parsed_body.fetch("code")
    assert_equal 14_000, month_total(8)
  end

  # Review fix 3. Only the three most recent withdrawals are offered, but she (or Mia keeping her answer) can name
  # an older one that still has cash.
  test "an older withdrawal than the three offered can still be named" do
    oldest = withdraw(5000, "2026-07-01")
    newer_withdrawals
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    assert_not_includes draft.dig("cash_payment", "candidates").pluck("financial_source_event_id"), oldest.id
    confirm(draft, cash_withdrawal_event_id: oldest.id)
    assert_response :success, response.body
    assert_equal [ 1000, 4000 ], [ budget_actual(@cash, month: 7) - 2000, budget_actual(@dining, month: 7) ], "$20 of July's Cash is the Jul 20 withdrawal"
  end

  test "Mia changing a linked purchase keeps its older withdrawal after newer ones arrive" do
    oldest = withdraw(5000, "2026-07-01")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: oldest.id)
    assert_response :success, response.body
    newer_withdrawals

    record = TransactionDraft.find(draft.fetch("id"))
    HouseholdFinance::PurchaseChange.apply!(household: @household, user: @user, cohort_membership: nil, key: "mia-change-#{SecureRandom.hex(4)}",
      payload: { "transaction_draft_id" => record.id, "new_amount_cents" => 3500 }, before: HouseholdFinance::PurchaseChange.snapshot(record))
    purchase = record.reload.confirmed_transaction
    assert_equal [ oldest.id, 3500 ], purchase.metadata.fetch("cash_withdrawal").values_at("financial_source_event_id", "amount_cents")
    assert_equal [ 1500, 3500 ], [ budget_actual(@cash, month: 7) - 2000, budget_actual(@dining, month: 7) ]
  end

  test "Mia can't change an unanswered cash purchase and says why" do
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft)
    withdraw(10_000, "2026-08-03")
    record = TransactionDraft.find(draft.fetch("id"))
    error = assert_raises(HouseholdFinance::PurchaseChange::Stale) do
      HouseholdFinance::PurchaseChange.apply!(household: @household, user: @user, cohort_membership: nil, key: "mia-change-#{SecureRandom.hex(4)}",
        payload: { "transaction_draft_id" => record.id, "new_amount_cents" => 3500 }, before: HouseholdFinance::PurchaseChange.snapshot(record))
    end
    assert_equal "Tasi Demo Cafe was paid in cash, and I need to know which cash you took out paid for it before I change it, so I left it as it was. " \
      "Answer \"Paid with cash\" for it in Review, then ask me again. Nothing changed.", error.message
  end

  # Review fix (round 3). A card line she says is a purchase she logged as cash proves it went on her card: the $100 she
  # took out still counts, and the lunch counts once on its own. $140, not $100.
  test "Same purchase on a card line takes a cash purchase off the cash it named" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_equal [ 6000, 4000, 10_000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    purchase = TransactionDraft.find(draft.fetch("id")).confirmed_transaction

    statement = build_source([ [ "POS PURCHASE TASI DEMO CAFE", -4000, "purchase", "2026-08-05" ] ])
    line = statement[:revision].financial_source_events.sole
    row = plan(statement).fetch("attention").sole
    assert_equal "same_purchase", row.fetch("kind")
    assert_equal "Same purchase as Tasi Demo Cafe on Aug 5 ($40.00), already in your spending? If it is, it went on this card, so it no longer counts as paid from the cash you took out on Aug 3.",
      row.fetch("question")

    same_purchase(statement, line, row)
    assert_response :success, response.body
    assert_equal [ "match", purchase.id ], SourceReviewHead.find_by!(financial_source_event: line).approved_version.attributes.values_at("disposition", "matched_transaction_id")
    assert_nil purchase.reload.metadata["cash_withdrawal"]
    marker = purchase.metadata.fetch("paid_by_card")
    assert_equal [ SourceReviewHead.find_by!(financial_source_event: line).id, line.id, withdrawal.id ],
      [ marker["source_review_head_id"], marker["financial_source_event_id"], marker.dig("previous_link", "financial_source_event_id") ]
    assert marker["at"].present?
    assert HouseholdFinance::CashPayment.paid_in_cash?(TransactionDraft.find(draft.fetch("id"))), "Her original declaration survives undo"
    audit = @household.household_audit_events.find_by!(event_type: "cash_purchase.paid_by_card")
    assert_equal [ "HouseholdTransaction", purchase.id, withdrawal.id ], [ audit.auditable_type, audit.auditable_id, audit.metadata.dig("cash_withdrawal", "financial_source_event_id") ]

    # The $100 cash still counts when it was taken out, and the lunch counts once, in Dining.
    assert_equal [ 10_000, 4000, 14_000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8), month_total(8) ]
    assert_equal 14_000, HouseholdFinance::Money.cents!(spending_report("2026-08-01", "2026-08-31").dig("totals", "actual"))
    assert_equal 14_000, analyzer("2026-08-01", "2026-08-31").fetch(:observed_spending_cents)
    assert_equal 14_000, mia_month(8).fetch(:spent_so_far_cents)
    assert_empty budget_plan.fetch("cash_purchase_questions"), "A card purchase isn't asked which cash paid for it"
    assert_nil HouseholdFinance::CashPayment.presentation(TransactionDraft.find(draft.fetch("id")))

    # A new cash purchase can name the whole $100 again.
    later = log_purchase("Tasi Demo Bakery", 100, "2026-08-06", @dining, paid_with_cash: true)
    assert_equal "Paid with the $100 you took out on Aug 3?", later.dig("cash_payment", "question")
  end

  test "Different purchase on a card line keeps the cash purchase on the cash it named" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    statement = build_source([ [ "POS PURCHASE TASI DEMO CAFE", -4000, "purchase", "2026-08-05" ] ])
    line = statement[:revision].financial_source_events.sole
    row = plan(statement).fetch("attention").sole
    approve(statement, [ { event_id: line.id, decision: "different", shown: row.slice("event_type", "category_id"), expected_head: row.fetch("expected_head") } ])
    assert_response :success, response.body

    purchase = TransactionDraft.find(draft.fetch("id")).confirmed_transaction
    assert_equal withdrawal.id, purchase.metadata.dig("cash_withdrawal", "financial_source_event_id")
    assert HouseholdFinance::CashPayment.paid_in_cash?(TransactionDraft.find(draft.fetch("id")))
    assert_nil @household.household_audit_events.find_by(event_type: "cash_purchase.paid_by_card")
    assert_equal [ 6000, 4000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ]
  end

  # Review fix (round 3). Home counts the same purchases Review asks about: every year, all of them, while Review lists
  # the newest CashDrawdowns::MAX_OPEN_QUESTIONS and says how many there are.
  test "Home counts every cash question Review has, in any year" do
    withdraw(5000, "2025-12-20")
    confirmed_cash_purchase("Tasi Demo Cafe", 1200, "2025-12-22")
    assert_equal [ 1, 1, 1 ], [ budget_plan.fetch("cash_purchase_questions").length, budget_plan.dig("cash_purchase_questions_meta", "total_count"), home_cash_question_count ]

    withdraw(30_000, "2026-08-03")
    21.times { |index| confirmed_cash_purchase("Tasi Demo Market #{index + 1}", 500, (Date.new(2026, 8, 4) + index).iso8601) }
    listed = budget_plan
    assert_equal HouseholdFinance::CashDrawdowns::MAX_OPEN_QUESTIONS, listed.fetch("cash_purchase_questions").length
    assert_equal({ "total_count" => 22, "limit" => 20 }, listed.fetch("cash_purchase_questions_meta"))
    assert_equal 22, home_cash_question_count
    assert_equal "2026-08-24", listed.fetch("cash_purchase_questions").first.fetch("occurred_on"), "Newest first"
  end

  # Review fix (round 3). Asking about many purchases reads the withdrawals once, and the purchase cards on the same
  # page reuse what Review's list worked out.
  test "cash questions read the withdrawals once, however many purchases she has" do
    withdraw(10_000, "2026-07-20")
    withdraw(10_000, "2026-08-03")
    2.times { |index| confirmed_cash_purchase("Tasi Demo Cafe #{index + 1}", 500, "2026-08-0#{index + 4}") }
    drawdowns = HouseholdFinance::CashDrawdowns.new(@household.reload)
    few = sql_count { assert_equal 2, drawdowns.open_questions.length }
    4.times { |index| confirmed_cash_purchase("Tasi Demo Bakery #{index + 1}", 500, "2026-08-1#{index}") }
    drawdowns = HouseholdFinance::CashDrawdowns.new(@household.reload)
    many = sql_count { assert_equal 6, drawdowns.open_questions.length }
    assert_equal few, many

    drafts = @household.transaction_drafts.where(status: "confirmed").includes(confirmed_transaction: :transaction_splits).to_a
    cards = sql_count { assert_equal 6, drafts.count { |draft| HouseholdFinance::CashPayment.presentation(draft, drawdowns: drawdowns)&.dig(:open_question) } }
    assert_equal 0, cards
  end

  test "undoing Same purchase asks again and relinking counts correctly everywhere" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    statement = build_source([ [ "POS PURCHASE TASI DEMO CAFE", -4000, "purchase", "2026-08-05" ] ])
    line = statement[:revision].financial_source_events.sole
    same_purchase(statement, line, plan(statement).fetch("attention").sole)
    assert_response :success, response.body
    assert_money_everywhere(14_000)
    assert_equal 0, home_cash_question_count
    head = SourceReviewHead.find_by!(financial_source_event: line)
    version = head.approved_version
    approve(statement, [ { event_id: line.id, decision: "different", shown: { event_type: version.event_type, category_id: nil }, expected_head: { approved_version_id: version.id, lock_version: head.lock_version, account_version_id: version.source_account_identity_version_id } } ])
    assert_response :success, response.body
    head.reload
    version = head.approved_version
    approve(statement, [ { event_id: line.id, decision: "edited", expected_head: { approved_version_id: version.id, lock_version: head.lock_version, account_version_id: version.source_account_identity_version_id }, edit: { kind: "spending", category_id: @dining.id } } ])
    assert_response :success, response.body
    assert_money_everywhere(18_000)
    question = budget_plan.fetch("cash_purchase_questions").sole
    assert_equal withdrawal.id, question.fetch("candidates").first.fetch("financial_source_event_id")
    assert_equal 1, home_cash_question_count
    assert_nil TransactionDraft.find(draft.fetch("id")).confirmed_transaction.metadata["cash_withdrawal"]
    cash_answer(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_money_everywhere(14_000)
    assert_equal [ 6000, 8000 ], [ budget_actual(@cash, month: 8), budget_actual(@dining, month: 8) ]
    assert_equal 0, home_cash_question_count
  end

  test "removing the matching statement asks again without silently restoring cash" do
    withdrawal = withdraw(10_000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft, cash_withdrawal_event_id: withdrawal.id)
    statement = build_source([ [ "POS PURCHASE TASI DEMO CAFE", -4000, "purchase", "2026-08-05" ] ])
    same_purchase(statement, statement[:revision].financial_source_events.sole, plan(statement).fetch("attention").sole)
    delete "/api/v1/document_imports/#{statement[:import].id}", headers: headers
    assert_response :unprocessable_entity, response.body
    configured = S3Service.method(:configured?)
    begin
      S3Service.define_singleton_method(:configured?) { true }
      post "/api/v1/document_imports/#{statement[:import].id}/reprocess", headers: headers
      assert_response :unprocessable_entity, response.body
    ensure
      S3Service.define_singleton_method(:configured?, configured)
    end
    assert_equal 0, home_cash_question_count
    # Model a historical import outside the current picture. Public deletion retains approved records.
    statement[:import].update_column(:financial_generation, -1)
    assert_money_everywhere(14_000)
    assert_equal 1, home_cash_question_count
    assert_equal withdrawal.id, budget_plan.fetch("cash_purchase_questions").sole.fetch("candidates").first.fetch("financial_source_event_id")
    cash_answer(draft, cash_withdrawal_event_id: withdrawal.id)
    assert_response :success, response.body
    assert_money_everywhere(10_000)
  end

  test "a partial cash answer can be replayed" do
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    confirm(draft)
    withdrawal = withdraw(2000, "2026-08-03")
    2.times do
      cash_answer(draft, cash_withdrawal_event_id: withdrawal.id)
      assert_response :success, response.body
    end
    assert_money_everywhere(4000)
  end

  test "a prepared update cannot overwrite a newer cash declaration" do
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining)
    record = TransactionDraft.find(draft.fetch("id"))
    operation = HouseholdFinance::Operations::Transaction::DraftUpdate.new(@household)
    prepared = operation.prepare(draft_id: record.id, merchant: "Changed cafe", source_type: "manual_ui")
    record.update!(draft_payload: HouseholdFinance::CashPayment.with_paid_in_cash(record.draft_payload, true))
    assert_raises(HouseholdFinance::Operations::Base::StaleOperation) do
      @household.with_lock { operation.execute!(prepared, source: "manual_ui") }
    end
    assert_equal "Tasi Demo Cafe", record.reload.merchant
  end

  test "a kept pending Yes explains partial coverage" do
    withdrawal = withdraw(2000, "2026-08-03")
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    record = TransactionDraft.find(draft.fetch("id"))
    record.update!(draft_payload: HouseholdFinance::CashPayment.with_answer(record.draft_payload, withdrawal.id))
    message = HouseholdFinance::CashPayment.presentation(record).fetch(:message)
    assert_includes message, "$20 already counted"
    assert_includes message, "the other $20 still counts on its own"
    refute_includes message, "won't add"
  end

  test "document draft serialization shares one drawdown calculation" do
    source = build_source([ [ "Tasi Demo ATM", -10_000, "cash_withdrawal", "2026-08-03" ] ])
    3.times do |index|
      draft = confirmed_cash_purchase("Demo cafe #{index}", 1000, "2026-08-05")
      draft.update!(financial_document_import: source[:import])
    end
    creations = 0
    trace = TracePoint.new(:call) { |event| creations += 1 if event.defined_class == HouseholdFinance::CashDrawdowns && event.method_id == :initialize }
    trace.enable do
      controller = Api::V1::DocumentImportsController.new
      result = controller.send(:serialize_document_import, source[:import])
      assert_equal 3, result.fetch(:transaction_drafts).length
    end
    assert_equal 1, creations
  end

  test "scorecard answers with an eligible withdrawal older than those offered" do
    require Rails.root.join("lib/scorecard/approval_simulator")
    older = withdraw(10_000, "2026-07-01")
    newer_withdrawals
    draft = log_purchase("Tasi Demo Cafe", 40, "2026-08-05", @dining, paid_with_cash: true)
    refute_includes draft.dig("cash_payment", "candidates").pluck("financial_source_event_id"), older.id
    simulator = Scorecard::ApprovalSimulator.allocate
    simulator.instance_variable_set(:@household, @household)
    simulator.instance_variable_set(:@row_answers, { 0 => { "event_id" => "old-cash" }, older.id => { "event_id" => "old-cash" } })
    assert_equal older.id, simulator.send(:cash_withdrawal_answer, "old-cash", TransactionDraft.find(draft.fetch("id")))
    assert_equal "elsewhere", simulator.send(:cash_withdrawal_answer, nil, TransactionDraft.find(draft.fetch("id")))
    assert_raises(RuntimeError) { simulator.send(:cash_withdrawal_answer, "missing", TransactionDraft.find(draft.fetch("id"))) }
  end

  def assert_money_everywhere(cents)
    assert_equal cents, month_total(8)
    assert_equal cents, HouseholdFinance::Money.cents!(spending_report("2026-08-01", "2026-08-31").dig("totals", "actual"))
    assert_equal cents, analyzer("2026-08-01", "2026-08-31").fetch(:observed_spending_cents)
    assert_equal cents, mia_month(8).fetch(:spent_so_far_cents)
  end

  private

  def headers = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def log_purchase(merchant, dollars, on, category, paid_with_cash: false)
    post "/api/v1/transaction_drafts", params: { transaction_draft: { occurred_on: on, merchant: merchant, amount: dollars, budget_category_id: category.id }.merge(paid_with_cash ? { paid_with_cash: true } : {}) },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :created, response.body
    response.parsed_body.fetch("transaction_draft")
  end

  def confirm(draft, **answer)
    post "/api/v1/transaction_drafts/#{draft.fetch('id')}/confirm", params: { transaction_draft: answer }, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
  end

  def cash_answer(draft, **answer)
    post "/api/v1/transaction_drafts/#{draft.fetch('id')}/cash_answer", params: { transaction_draft: answer }, headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
  end

  # Three withdrawals after Jul 1, each in its own statement: $20 on Jul 20, $25 on Aug 1, $30 on Aug 3.
  def newer_withdrawals
    [ [ 2000, "2026-07-20", "Tasi Demo Branch withdrawal" ], [ 2500, "2026-08-01", "Talun Demo ATM" ], [ 3000, "2026-08-03", "Hagatna Demo ATM" ] ]
      .map { |cents, on, merchant| withdraw(cents, on, merchant: merchant) }
  end

  def move_to_transfer(withdrawal)
    version = SourceReviewHead.find_by!(financial_source_event: withdrawal).approved_version
    head = version.source_review_head
    approve(@sources.fetch(withdrawal.id), [ { event_id: withdrawal.id, expected_head: { approved_version_id: head.approved_version_id, lock_version: head.lock_version, account_version_id: version.source_account_identity_version_id },
      decision: "edited", edit: { kind: "moved" } } ])
    assert_response :success, response.body
  end

  # A statement with one ATM withdrawal, approved as read into Cash.
  def withdraw(cents, on, merchant: "Tasi Demo ATM withdrawal")
    source = build_source([ [ merchant, -cents, "cash_withdrawal", on ] ])
    event = source[:revision].financial_source_events.sole
    row = plan(source).fetch("ready").sole
    assert_equal @cash.id, row.fetch("category_id")
    approve(source, [ { event_id: event.id, decision: "as_read", shown: row.slice("event_type", "category_id") } ], expect_ready_ids: [ event.id ])
    assert_response :success, response.body
    (@sources ||= {})[event.id] = source
    event
  end

  def plan(source)
    get "/api/v1/document_imports/#{source[:import].id}/source_review", params: { revision_id: source[:revision].id }, headers: headers
    assert_response :success
    response.parsed_body.dig("source_review", "participant_review", "plan")
  end

  def approve(source, lines, **extra)
    post "/api/v1/document_imports/#{source[:import].id}/review/approve_lines", params: { revision_id: source[:revision].id, input: { lines: lines, **extra } },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
  end

  def same_purchase(source, event, row)
    approve(source, [ { event_id: event.id, decision: "same_purchase", match_transaction_id: row.dig("purchase_match", "transaction_id"),
      shown: row.slice("event_type", "category_id"), expected_head: row.fetch("expected_head") } ])
  end

  # A cash purchase she confirmed before any withdrawal it could have come from was approved.
  def confirmed_cash_purchase(merchant, cents, on)
    date = Date.iso8601(on)
    period = HouseholdFinance::AnnualBudgetManager.new(@household, year: date.year).current_period_for(date)
    row = @household.household_transactions.create!(budget_period: period, occurred_on: date, merchant: merchant, total_amount_cents: cents, source_type: "manual_chat", status: "confirmed")
    row.transaction_splits.create!(budget_category: @dining, amount_cents: cents)
    @household.transaction_drafts.create!(occurred_on: date, merchant: merchant, total_amount_cents: cents, source_type: "manual_chat", status: "confirmed", confirmed_transaction: row,
      draft_payload: { HouseholdFinance::CashPayment::PAYLOAD_KEY => HouseholdFinance::CashPayment.participant_payload })
  end

  def home_cash_question_count
    get "/api/v1/workspace", headers: headers
    assert_response :success
    response.parsed_body.dig("dashboard", "action_center", "cash_question_count")
  end

  def sql_count
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:cached] || payload[:name].in?(%w[SCHEMA TRANSACTION]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  def budget_plan
    get "/api/v1/budget", params: { year: 2026 }, headers: headers
    assert_response :success
    response.parsed_body.fetch("annual_plan")
  end

  def budget_actual(category, month:)
    HouseholdFinance::Money.cents(budget_plan.fetch("rows").find { |row| row["id"] == category.id }.fetch("months")[month - 1].fetch("actual"))
  end

  def month_total(month)
    budget_plan.fetch("rows").sum { |row| HouseholdFinance::Money.cents(row.fetch("months")[month - 1].fetch("actual")) }
  end

  def spending_report(start_on, end_on)
    get "/api/v1/spending_report", params: { start_on: start_on, end_on: end_on }, headers: headers
    assert_response :success
    response.parsed_body.fetch("spending_report")
  end

  def analyzer(from, to) = SpendingPatterns::Analyzer.new(@household.reload, today: Date.new(2026, 11, 1), from: from, to: to).call

  def mia_month(month)
    plan = HouseholdFinance::AnnualBudgetManager.new(@household.reload, year: 2026).read_only_plan_data
    HouseholdFinance::MiaMonthAnswer.new(@household, annual_plan: plan, month: month).call
  end

  # rows: [merchant, signed cents, kind, posted date]
  def build_source(rows)
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "talun-demo-#{SecureRandom.hex(3)}.csv", content_type: "text/csv", byte_size: 10,
      s3_key: "synthetic/#{SecureRandom.hex(8)}.csv", checksum_sha256: SecureRandom.hex(32))
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    events = rows.each_with_index.map do |(name, cents, type, on), index|
      { account_key: "talun-checking", row_kind: "posted", limitations: [], event_type: type, signed_amount_cents: cents, posted_on: on, merchant: name, locator: { page: 1, row: index + 1 } }
    end
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: [ { account_key: "talun-checking", account_basis: "asset", label: "Talun Demo Checking ····4410" } ], events: events, reported_row_count: events.length },
      coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
    document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: document)
  end
end
