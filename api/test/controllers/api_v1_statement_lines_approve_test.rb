require "test_helper"
require_relative "../support/savings_challenge_test_support"
require_relative "../support/persona_test_helper"

# Lets one test make the household lock look busy; inert unless switched on.
module LockWaitSwitch
  class << self; attr_accessor :on; end
  def lock!(*) = LockWaitSwitch.on ? raise(ActiveRecord::LockWaitTimeout, "timed out") : super
end
Household.prepend(LockWaitSwitch)

# "Approve the rest" must save exactly the lines that looked right, all or none, and be safe to repeat.
class ApiV1StatementLinesApproveTest < ActionDispatch::IntegrationTest
  include SavingsChallengeTestSupport
  include PersonaTestHelper
  setup do
    @user = User.create!(clerk_id: "lines-#{SecureRandom.hex(8)}", email: "lines-#{SecureRandom.hex(8)}@example.com", role: "participant", invitation_status: "accepted")
    @household = HouseholdFinance::WorkspaceResolver.new(@user).household
    @groceries = @household.budget_categories.create!(name: "Groceries", stack_key: "discretionary", sort_order: 0)
    @clothing = @household.budget_categories.create!(name: "Clothing", stack_key: "discretionary", sort_order: 1)
    @source = build_source
    @events = @source[:revision].financial_source_events.includes(:financial_source_evidence).order(:position).index_by { |event| merchant_of(event) }
    suggest(@events.fetch("Payless"), @groceries)
  end

  test "the plan sorts the statement into what looks right and the few lines that need an answer" do
    plan = review_plan
    assert_equal 5, plan.fetch("total")
    assert_equal 0, plan.fetch("done")
    assert_equal [ "Payroll", "Payless" ].map { |name| @events.fetch(name).id }, plan.fetch("ready_event_ids")
    kinds = plan.fetch("attention").to_h { |row| [ row.fetch("merchant"), row.fetch("kind") ] }
    assert_equal({ "Ross" => "no_category", "Own savings" => "transfer", "Unreadable" => "unclear" }, kinds)
    question = plan.fetch("attention").find { |row| row["merchant"] == "Own savings" }
    assert_equal "Did this move between your own accounts?", question.fetch("question")
    assert_equal %w[Yes No], question.fetch("answers").pluck("label")
    assert_equal "2026-07-02", plan.fetch("first_on")
    assert_equal "unchecked", plan.fetch("totals_check")
  end

  test "the plan says plainly whether the printed totals disagree, the line count differs, or nothing could be checked" do
    presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, @source[:revision], user: @user)
    balanced = { "accounts" => [ { "arithmetic_balanced" => true, "balance_residual_cents" => 0, "debit_residual_cents" => 0, "credit_residual_cents" => 0, "row_count_matches" => true } ], "row_census" => { "matches_reported" => true }, "page_coverage" => { "all_processed" => true } }
    {
      balanced => "matches",
      balanced.merge("accounts" => [ balanced["accounts"].first.merge("balance_residual_cents" => 4_250, "arithmetic_balanced" => false) ]) => "mismatch",
      balanced.merge("page_coverage" => { "all_processed" => false }) => "mismatch",
      balanced.merge("row_census" => { "matches_reported" => false }) => "count",
      balanced.merge("accounts" => [ balanced["accounts"].first.merge("row_count_matches" => false) ]) => "count",
      { "accounts" => [ { "arithmetic_balanced" => false, "balance_residual_cents" => nil } ], "row_census" => { "matches_reported" => nil } } => "unchecked"
    }.each do |report, expected|
      revision = @source[:revision]
      revision.define_singleton_method(:reconciliation) { report }
      assert_equal expected, presenter.plan_summary.fetch(:totals_check), report.inspect
    end
  end

  test "a household's suggested category is shown for approval together with the other lines" do
    @clothing.update!(active: false)
    @groceries.update!(name: "Flexible spending")
    plan = review_plan
    ross = plan.fetch("ready").find { |row| row["merchant"] == "Ross" }
    assert_equal "Flexible spending", ross.fetch("category_name")
    assert_equal @groceries.id, ross.fetch("category_id")
    assert_includes plan.fetch("ready_event_ids"), ross.fetch("event_id")
    assert_empty @household.household_transactions

    approve_lines({ lines: [ { event_id: ross.fetch("event_id"), decision: "as_read", shown: ross.slice("event_type", "category_id") } ] })
    assert_response :success, response.body
    assert_equal @groceries.id, @household.household_transactions.sole.transaction_splits.sole.budget_category_id
    assert_equal 500, @household.household_transactions.sole.total_amount_cents
  end

  test "an old phone edit cannot overwrite a desktop answer to the same statement line" do
    old = review_plan.fetch("ready").find { |line| line["merchant"] == "Payless" }
    first = { event_id: old.fetch("event_id"), expected_head: old.fetch("expected_head"), decision: "edited", edit: { kind: "spending", category_id: @clothing.id } }
    approve_lines({ lines: [ first ] })
    assert_response :success
    approved = SourceReviewHead.find_by!(financial_source_event_id: old.fetch("event_id")).approved_version
    assert_equal @clothing.id, approved.budget_category_id
    assert_no_difference "SourceReviewVersion.count" do
      approve_lines({ lines: [ first.merge(edit: { kind: "spending", category_id: @groceries.id }) ] })
      assert_response :conflict
    end
    assert_includes response.parsed_body.fetch("errors").join, "another window"
    assert_no_difference "SourceReviewVersion.count" do
      approve_lines({ lines: [ first.except(:expected_head).merge(edit: { kind: "spending", category_id: @groceries.id }) ] })
      assert_response :conflict
    end
    assert_equal @clothing.id, approved.source_review_head.reload.approved_version.budget_category_id
  end

  test "approving the rest links the account, saves exactly those lines and counts only categorized spending" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ expect_ready_ids: ready, lines: as_read(ready) })
    assert_response :success
    assert_equal({ "approved" => 2, "left_out" => 0, "unchanged" => 0, "complete" => false }, response.parsed_body.fetch("result"))
    assert_equal ready.sort, SourceReviewHead.where(household: @household).where.not(approved_version_id: nil).pluck(:financial_source_event_id).sort
    assert_equal 1, @household.household_transactions.where(status: "confirmed").count
    assert_equal 1_000, @household.household_transactions.sole.total_amount_cents
    assert_equal @groceries.id, @household.household_transactions.sole.transaction_splits.sole.budget_category_id
    # A system label such as "Spreadsheet account" is never saved as her account's name.
    assert_equal "Bank account", SourceTrackedAccount.where(household: @household).sole.label
    # Nothing she did not see is touched.
    assert_nil SourceReviewHead.find_by(financial_source_event_id: @events.fetch("Ross").id)&.approved_version_id
    assert_nil SourceReviewHead.find_by(financial_source_event_id: @events.fetch("Own savings").id)&.approved_version_id
    plan = review_plan
    assert_equal 2, plan.fetch("done")
    assert_empty plan.fetch("ready_event_ids")
  end

  test "repeating the same request changes nothing" do
    ready = review_plan.fetch("ready_event_ids")
    body = { expect_ready_ids: ready, lines: as_read(ready) }
    approve_lines(body, key: "same-key")
    approve_lines(body, key: "same-key")
    assert_response :success
    assert_equal({ "approved" => 0, "left_out" => 0, "unchanged" => 2, "complete" => false }, response.parsed_body.fetch("result"))
    assert_equal 2, SourceReviewVersion.where(household: @household).count
    assert_equal 1, SourceAccountIdentityVersion.where(household: @household).count
    assert_equal 1, @household.household_transactions.count
  end

  test "a request that no longer matches what was on screen saves nothing" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ expect_ready_ids: ready.first(1), lines: as_read(ready) })
    assert_response :conflict
    assert_match(/changed while you were reviewing/, response.parsed_body.fetch("errors").first)
    assert_equal 0, SourceReviewVersion.where(household: @household).count
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
  end

  test "one line that cannot be saved rolls the whole request back" do
    ready = review_plan.fetch("ready_event_ids")
    lines = as_read(ready) + [ { event_id: @events.fetch("Ross").id, decision: "as_read", shown: { category_id: nil, event_type: "purchase" } } ]
    approve_lines({ lines: lines })
    assert_response :conflict
    assert_equal 0, SourceReviewVersion.where(household: @household).count
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
    assert_equal 0, @household.household_transactions.count
    assert_equal 0, SourceTrackedAccount.where(household: @household).count
  end

  test "a line with no category cannot be approved as read, but choosing one counts it as spending" do
    ross = @events.fetch("Ross")
    approve_lines({ lines: [ { event_id: ross.id, decision: "as_read" } ] })
    assert_response :conflict
    approve_lines({ lines: [ { event_id: ross.id, decision: "edited", edit: { kind: "spending", merchant: "Ross", posted_on: "2026-07-04", amount_cents: 500, category_id: @groceries.id } } ] })
    assert_response :success
    assert_equal 500, @household.household_transactions.sole.total_amount_cents
    version = SourceReviewHead.find_by!(financial_source_event_id: ross.id).approved_version
    assert_equal @groceries.id, version.budget_category_id
  end

  test "leaving a line out keeps it represented but never counts it" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ lines: ready.map { |id| { event_id: id, decision: "leave_out" } } })
    assert_response :success
    assert_equal 2, response.parsed_body.dig("result", "left_out")
    assert_equal %w[exclude], SourceReviewVersion.where(household: @household).pluck(:disposition).uniq
    assert_equal 0, @household.household_transactions.count
  end

  test "the statement is finished once every line is answered, and the uncertainty stays on the record" do
    ready = review_plan.fetch("ready_event_ids")
    ross, savings = @events.fetch("Ross"), @events.fetch("Own savings")
    approve_lines({ lines: as_read(ready + [ savings.id ]) + [
      { event_id: @events.fetch("Unreadable").id, decision: "leave_out" },
      { event_id: ross.id, decision: "edited", edit: { kind: "spending", merchant: "Ross", posted_on: "2026-07-04", amount_cents: 500, category_id: @groceries.id } }
    ], coverage_answer: "nothing_missing" })
    assert_response :success
    assert_equal true, response.parsed_body.dig("result", "complete")
    approval = SourceRevisionApproval.where(household: @household).sole
    assert_equal "qualified", approval.coverage_status
    assert_includes approval.deficiencies, "account_period_unknown"
    assert_equal 0, @household.household_transactions.where(financial_source_event: savings).count
  end

  test "a participant can finish a statement before their program's first release" do
    coach = User.create!(clerk_id: "prelaunch-coach", email: "prelaunch-coach@example.invalid", role: "coach", invitation_status: "accepted")
    cohort = Cohort.create!(name: "Prelaunch", status: "enrolling", created_by_user: coach)
    membership = CohortMembership.create!(cohort: cohort, user: @user, role: "participant")
    persona = create_persona(creator: coach, config: persona_configuration(assistant_name: "Mel's Mia"))
    voice = publish_persona(persona, actor: coach)
    runtime = Mia::ParticipantRuntimeResolver.new(user: @user, cohort_membership: membership).call
    assert_equal voice.id, runtime.persona.version_id
    assert_equal "Mel's Mia", runtime.persona.name
    assert_nil cohort.cohort_persona_assignment
    post "/api/v1/mia/messages", params: { message: "I stayed under my grocery budget this week", year: 2026, month: 7 }, headers: headers, as: :json
    assert_response :created
    assert_equal "Mel's Mia", response.parsed_body.dig("assistant_message", "author")
    assert_equal voice.id, ChatMessage.find(response.parsed_body.dig("assistant_message", "id")).coach_persona_version_id
    ready = review_plan.fetch("ready_event_ids")
    ross, savings = @events.fetch("Ross"), @events.fetch("Own savings")
    approve_lines({ lines: as_read(ready + [ savings.id ]) + [
      { event_id: @events.fetch("Unreadable").id, decision: "leave_out" },
      { event_id: ross.id, decision: "edited", edit: { kind: "spending", merchant: "Ross", posted_on: "2026-07-04", amount_cents: 500, category_id: @groceries.id } }
    ], coverage_answer: "nothing_missing" })
    assert_response :success
    assert_equal true, response.parsed_body.dig("result", "complete")
    assert_equal 5, SourceReviewHead.where(household: @household).where.not(approved_version_id: nil).count
    assert SourceRevisionApproval.exists?(household: @household)
  end

  test "a schema one household draft goes live with Statements and completes review" do
    coach = persona_user
    cohort = cohort_for(coach, name: "Household go live")
    CohortMembership.create!(cohort: cohort, user: @user, role: "participant")
    publish_persona(create_persona(creator: coach), actor: coach)
    brand = cohort.coach_workspace.workspace_brand_configuration
    brand_publisher = Branding::Publisher.new(configuration: brand, actor: coach)
    preview = brand_publisher.preview!(expected_draft_revision: brand.draft_revision)
    brand_publisher.publish!(expected_preview_digest: preview, expected_draft_revision: brand.draft_revision, expected_current_version_id: brand.current_published_version_id, idempotency_key: "household-brand")
    configuration = cohort.cohort_experience_configuration
    old_config = { "schema_version" => 1, "optional_modules" => { "cfo_filter" => true, "optionality" => false } }
    configuration.update!(draft_config: old_config, last_edited_by_user: coach)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    old_version = publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)
    old_release = CohortReleases::Sealer.new(cohort: cohort, actor: coach).call!(request_key: "old-household", expected_bundle_digest: CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call.bundle_digest)
    old_attributes = old_release.attributes.deep_dup
    post "/api/v1/admin/cohorts/#{cohort.id}/experience_configuration/preview", params: { experience_configuration: { draft_revision: configuration.draft_revision, upgrade_to_current: true } }, headers: { "Authorization" => "Bearer test_token_#{coach.id}" }, as: :json
    assert_response :success
    assert_equal 4, configuration.reload.draft_config.fetch("schema_version")
    assert_equal "This update adds Statements", response.parsed_body.dig("preview", "upgrade_notice")
    assert_equal true, configuration.draft_config.dig("optional_modules", "cfo_filter")
    assert_equal old_config, old_version.reload.config
    post "/api/v1/admin/cohorts/#{cohort.id}/experience_configuration/preview", params: { experience_configuration: { draft_revision: configuration.draft_revision, upgrade_to_current: true } }, headers: { "Authorization" => "Bearer test_token_#{coach.id}" }, as: :json
    assert_response :success
    assert_equal "This update adds Statements", response.parsed_body.dig("preview", "upgrade_notice")
    digest = response.parsed_body.dig("preview", "digest")
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: old_version.id)
    cohort.reload
    release = CohortReleases::Sealer.new(cohort: cohort, actor: coach).call!(request_key: "current-household", expected_bundle_digest: CohortReleases::CandidateBuilder.new(cohort: cohort, strict: true).call.bundle_digest)
    assert_equal 6, release.tool_registry_version
    launcher = CohortReleases::InitialLauncher.new(cohort: cohort, actor: coach)
    launcher.call!(release_id: release.id, preview_digest: launcher.preview.fetch(:preview_digest), request_key: "launch-household")
    approve_lines({ lines: @events.values.map { |event| { event_id: event.id, decision: "leave_out" } }, coverage_answer: "nothing_missing" })
    assert_response :success
    assert_equal true, response.parsed_body.dig("result", "complete")
    assert SourceRevisionApproval.exists?(household: @household)
    assert_equal old_attributes, old_release.reload.attributes
    assert old_release.integrity_valid?
  end

  test "an older release denies newer statement tools with a recoverable plain response" do
    coach = User.create!(clerk_id: "sealed-coach", email: "sealed-coach@example.invalid", role: "coach", invitation_status: "accepted")
    cohort = Cohort.create!(name: "Sealed program", status: "enrolling", created_by_user: coach)
    CohortMembership.create!(cohort: cohort, user: @user, role: "participant")
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    cohort.update!(active_cohort_release: cohort.cohort_releases.sole)
    assert_operator cohort.active_cohort_release.tool_registry_version, :<, 3
    approve_lines({ lines: as_read(review_plan.fetch("ready_event_ids")) })
    assert_response :forbidden
    assert_equal "savings_challenge_unavailable", response.parsed_body.fetch("code")
    assert_equal "This part of your program isn't available right now. Please contact your program team.", response.parsed_body.fetch("errors").sole
    assert_equal 0, SourceReviewVersion.where(household: @household).count
    get "/api/v1/workspace", headers: headers
    assert_response :success
    statement = response.parsed_body.dig("workspace", "capabilities", "modules").find { |item| item["id"] == "statements" }
    assert_equal false, statement&.fetch("enabled")
    assert_equal "Statements aren't available for your group yet. Please contact your program team.", statement.fetch("unavailable_message")
    %w[document_imports document_imports/presign document_imports/complete].each do |path|
      post "/api/v1/#{path}", params: {}, headers: headers, as: :json
      assert_response :forbidden
    end
  end

  test "a prelaunch coach can hide statement review" do
    coach = User.create!(clerk_id: "hidden-coach", email: "hidden-coach@example.invalid", role: "coach", invitation_status: "accepted")
    cohort = Cohort.create!(name: "Hidden statements", status: "enrolling", created_by_user: coach)
    CohortMembership.create!(cohort: cohort, user: @user, role: "participant")
    configuration = cohort.cohort_experience_configuration
    config = CohortExperience::Schema.upgrade(configuration.draft_config)
    config["optional_modules"]["statements"] = false
    configuration.update!(draft_config: config, last_edited_by_user: coach)
    publisher = CohortExperience::Publisher.new(configuration: configuration, actor: coach)
    digest = publisher.preview!(expected_draft_revision: configuration.draft_revision)
    publisher.publish!(expected_preview_digest: digest, expected_draft_revision: configuration.draft_revision, expected_current_version_id: nil)
    approve_lines({ lines: as_read(review_plan.fetch("ready_event_ids")) })
    assert_response :forbidden
    assert_equal "This part of your program isn't available right now. Please contact your program team.", response.parsed_body.fetch("errors").sole
    assert_equal 0, SourceReviewVersion.where(household: @household).count
    get "/api/v1/workspace", headers: headers
    assert_response :success
    statement = response.parsed_body.dig("workspace", "capabilities", "modules").find { |item| item["id"] == "statements" }
    assert_equal false, statement.fetch("enabled")
    post "/api/v1/document_imports/presign", params: {}, headers: headers, as: :json
    assert_response :forbidden
    # Publishing a release must retain the same coach-selected restriction.
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    cohort.update!(active_cohort_release: cohort.cohort_releases.sole)
    assert_equal 6, cohort.active_cohort_release.tool_registry_version
    approve_lines({ lines: as_read(review_plan.fetch("ready_event_ids")) })
    assert_response :forbidden
    assert_equal 0, SourceReviewVersion.where(household: @household).count
  end

  test "a participant retains their review when their challenge is unavailable" do
    coach = User.create!(clerk_id: "paused-coach", email: "paused-coach@example.invalid", role: "coach", invitation_status: "accepted")
    cohort = Cohort.create!(name: "Paused program", status: "enrolling", created_by_user: coach,
      savings_challenge_enabled: true, savings_challenge_release_hold: true)
    CohortMembership.create!(cohort: cohort, user: @user, role: "participant")
    approve_lines({ lines: as_read(review_plan.fetch("ready_event_ids")) })
    assert_response :forbidden
    assert_equal "savings_challenge_unavailable", response.parsed_body.fetch("code")
    assert_equal 0, SourceReviewVersion.where(household: @household).count
  end

  test "an account whose type is unknown asks before anything is saved" do
    other = build_source(basis: "unknown")
    post "/api/v1/document_imports/#{other[:import].id}/review/approve_lines", params: { revision_id: other[:revision].id, input: { lines: [ { event_id: other[:revision].financial_source_events.first.id, decision: "leave_out" } ] } },
      headers: headers.merge("Idempotency-Key" => SecureRandom.uuid), as: :json
    assert_response :unprocessable_entity
    assert_equal "Choose whether this is a bank account or a credit card.", response.parsed_body.fetch("errors").first
    assert_equal 0, SourceAccountIdentityVersion.where(household: @household).count
  end

  test "the account name and dates can be changed, and the same change twice is one change" do
    account = @source[:revision].financial_source_accounts.sole
    change = { lines: [], accounts: [ { source_account_id: account.id, account_basis: "liability", label: "Visa", period_start_on: "2026-07-01", period_end_on: "2026-07-31" } ] }
    approve_lines(change, key: "k1")
    approve_lines(change, key: "k2")
    assert_response :success
    identity = SourceAccountIdentityVersion.where(household: @household).sole
    assert_equal "Visa", identity.source_tracked_account.label
    assert_equal "liability", identity.source_tracked_account.account_basis
    assert_equal "2026-07-31", identity.statement_facts["period_end_on"]
  end

  test "only the participant who owns the household can approve" do
    %w[coach admin].each do |role|
      @user.update!(role: role)
      approve_lines({ lines: [ { event_id: @events.fetch("Payroll").id, decision: "as_read" } ] })
      assert_response :forbidden
    end
    assert_equal 0, SourceReviewVersion.where(household: @household).count
  end

  test "a merchant she already categorized keeps that category on the next statement" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ lines: as_read(ready) })
    later = build_source(rows: [ [ "Payless", -700, "purchase", 1 ] ])
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, later[:revision])
    assert_equal [ @groceries.id ], plan.lines.map(&:category_id)
    assert_empty plan.attention
  end

  test "a copy of a charge she already approved is flagged and can only be left out" do
    ready = review_plan.fetch("ready_event_ids")
    approve_lines({ lines: as_read(ready) })
    copy = build_source(rows: [ [ "Payless", -1_000, "purchase", 2 ] ])
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, copy[:revision])
    assert_equal [ :duplicate ], plan.attention.map(&:kind)
  end

  test "a long statement is approved a page at a time: exactly the lines on the page, all or none, and a retry changes nothing" do
    rows = (1..5).map { |index| [ "Pay #{index}", 10_000 + index, "income", index ] }
    long = build_source(rows: rows)
    ids = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, long[:revision]).ready_ids
    assert_equal 5, ids.length
    with_page_limit(2) do
      # Her screen sent each line with what it showed; a retry sends the same thing again.
      shown = as_read(ids, source: long).index_by { |line| line[:event_id] }
      page = ->(slice, **extra) { approve_lines({ expect_ready_ids: slice, paged: true, lines: slice.map { |id| shown[id] || { event_id: id, decision: "as_read" } } }.merge(extra), source: long) }
      # More than a page in one request is refused outright, and saves nothing.
      approve_lines({ expect_ready_ids: ids, lines: as_read(ids, source: long) }, source: long)
      assert_response :unprocessable_entity
      assert_equal 0, SourceReviewVersion.where(household: @household).count
      # Without paged: true the request must cover every open line, as before.
      approve_lines({ expect_ready_ids: ids.first(2), lines: as_read(ids.first(2), source: long) }, source: long)
      assert_response :conflict
      assert_equal 0, SourceReviewVersion.where(household: @household).count
      page.call(ids.first(2))
      assert_equal({ "approved" => 2, "left_out" => 0, "unchanged" => 0, "complete" => false }, response.parsed_body.fetch("result"))
      page.call(ids.first(2))
      assert_equal({ "approved" => 0, "left_out" => 0, "unchanged" => 2, "complete" => false }, response.parsed_body.fetch("result"))
      assert_equal 2, SourceReviewVersion.where(household: @household).count
      # A page that holds a line she was never shown as looking right saves nothing.
      page.call(ids[2, 1] + [ -1 ])
      assert_response :conflict
      assert_equal 2, SourceReviewVersion.where(household: @household).count
      page.call(ids[2, 2])
      page.call(ids.last(1), coverage_answer: "nothing_missing")
      assert_equal 5, SourceReviewVersion.where(household: @household).count
      assert_equal 1, SourceAccountIdentityVersion.where(household: @household).count
      assert_equal true, response.parsed_body.dig("result", "complete")
    end
  end

  test "a page that holds a line that no longer looks right is refused and saves nothing" do
    long = build_source(rows: [ [ "Pay 1", 10_000, "income", 1 ], [ "Pay 2", 10_001, "income", 2 ] ])
    ids = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, long[:revision]).ready_ids
    changed = build_source(rows: [ [ "Ross", -500, "purchase", 1 ] ])
    approve_lines({ expect_ready_ids: ids + changed[:revision].financial_source_events.pluck(:id), paged: true, lines: as_read(ids, source: long) }, source: long)
    assert_response :conflict
    assert_equal 0, SourceReviewVersion.where(household: @household).count
  end

  test "account numbers are hidden in every description she reads, and the statement's own words stay stored" do
    rows = [ [ "Coast360 transfer to own savings 00002468", -20_000, "transfer", 1 ], [ "Visa card payment 00009900", -25_000, "debt_payment", 2 ], [ "Ross #12345678 order $1234567.89", -500, "purchase", 3 ] ]
    source = build_source(rows: rows)
    event = source[:revision].financial_source_events.joins(:financial_source_evidence).first
    assert_equal "Coast360 transfer to own savings 00002468", event.financial_source_evidence.payload["merchant"]
    get "/api/v1/document_imports/#{source[:import].id}/source_review", params: { revision_id: source[:revision].id }, headers: headers
    review = response.parsed_body.fetch("source_review")
    shown = review.fetch("events").map { |row| row.dig("evidence", "merchant") }
    assert_includes shown, "Coast360 transfer to own savings ····2468"
    assert_includes shown, "Visa card payment ····9900"
    assert_includes shown, "Ross #····5678 order $1234567.89"
    plan_merchants = review.dig("participant_review", "plan", "attention").pluck("merchant")
    assert_includes plan_merchants, "Coast360 transfer to own savings ····2468"
    assert_includes plan_merchants, "Visa card payment ····9900"
    %w[00002468 00009900 12345678].each { |number| refute_includes (plan_merchants + shown + review.fetch("events").pluck("evidence").flat_map(&:values).grep(String)).join(" "), number }
  end

  test "an account is named in plain words: the bank when the file says it, never a system label" do
    names = ->(label, masked) { FinancialDocuments::SourceReview::AccountName.parts(label, masked) }
    assert_equal({ name: nil, last4: nil }, names.call("Spreadsheet account 1", nil))
    assert_equal({ name: nil, last4: "1234" }, names.call("Statement account ****1234", "****1234"))
    assert_equal({ name: "Bank of Guam checking", last4: "1234" }, names.call("Bank of Guam checking", "****1234"))
    assert_equal({ name: "Bank of Guam checking", last4: "1234" }, names.call("Bank of Guam checking · ****1234", nil))
    assert_equal({ name: nil, last4: "1234" }, names.call("Bank account ····1234", nil))
    assert_equal "Credit card ····1234", FinancialDocuments::SourceReview::AccountName.default_label("Spreadsheet account 1", "****1234", "liability")
    account = @source[:revision].financial_source_accounts.sole
    presenter = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, @source[:revision], user: @user)
    assert_equal [ nil, nil ], presenter.context(event_ids: []).fetch(:accounts).first.values_at(:name, :last4)
    approve_lines({ lines: [], accounts: [ { source_account_id: account.id, account_basis: "asset", label: "Bank of Guam checking" } ] })
    assert_equal "Bank of Guam checking", presenter.context(event_ids: []).fetch(:accounts).first.fetch(:name)
  end

  test "a merchant she categorized before keeps that category under different bank wording, and a conflicting reader guess is a question" do
    earlier = build_source(rows: [ [ "Ross Dededo GU", -1_000, "purchase", 1 ] ])
    approve_lines({ lines: [ { event_id: earlier[:revision].financial_source_events.sole.id, decision: "edited", edit: { kind: "spending", merchant: "Ross Dededo GU", posted_on: "2026-07-02", amount_cents: 1_000, category_id: @groceries.id } } ] }, source: earlier)
    assert_response :success
    shopping = @household.budget_categories.create!(name: "Shopping", stack_key: "discretionary", sort_order: 1)
    later = build_source(rows: [ [ "ROSS DRESS FOR LESS #123 HAGATNA GU", -700, "purchase", 3 ], [ "ROSS STORES #456 YIGO GU", -800, "purchase", 4 ], [ "Corner Cafe", -900, "purchase", 5 ] ])
    events = later[:revision].financial_source_events.includes(:financial_source_evidence).order(:position).to_a
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, later[:revision])
    # Her earlier answer arrives already chosen; an unfamiliar merchant is still a question.
    assert_equal [ @groceries.id, @groceries.id, nil ], plan.lines.map(&:category_id)
    assert_equal [ :no_category ], plan.attention.map(&:kind)
    # The reader guessed something else for one of them: ask with her own category, never overrule it silently.
    @household.transaction_drafts.create!(financial_document_import: later[:import], financial_source_event: events.second, occurred_on: events.second.posted_on, merchant: "Ross",
      total_amount_cents: 800, budget_category: shopping, source_type: "statement", status: "pending")
    plan = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, later[:revision])
    assert_equal [ :still_category, :no_category ].sort, plan.attention.map(&:kind).sort
    row = FinancialDocuments::SourceReview::ParticipantPresenter.new(@household, later[:revision], user: @user).plan_summary.fetch(:attention).find { |item| item[:kind] == :still_category }
    assert_equal "Still Groceries?", row.fetch(:question)
    assert_equal %w[Yes Change], row.fetch(:answers).pluck(:label)
    assert_equal @groceries.id, row.fetch(:category_id)
    assert_empty plan.ready_ids - events.first(1).map(&:id)
  end

  test "a category that comes only from her history is shown to her, and approving the rest saves exactly what was shown" do
    dining = @household.budget_categories.create!(name: "Dining out", stack_key: "discretionary", sort_order: 1)
    earlier = build_source(rows: [ [ "Zippy's", -1_000, "purchase", 1 ] ])
    approve_lines({ lines: [ { event_id: earlier[:revision].financial_source_events.sole.id, decision: "edited", edit: { kind: "spending", merchant: "Zippy's", posted_on: "2026-07-02", amount_cents: 1_000, category_id: dining.id } } ] }, source: earlier)
    assert_response :success
    later = build_source(rows: [ [ "Zippy's", -700, "purchase", 3 ], [ "Payroll", 20_000, "income", 4 ] ])
    plan = plan_for(later)
    zippys = plan.fetch("ready").find { |row| row["event_id"] == later[:revision].financial_source_events.order(:position).first.id }
    assert_equal({ "category_id" => dining.id, "category_name" => "Dining out", "as_before" => true, "event_type" => "purchase" }, zippys.slice("category_id", "category_name", "as_before", "event_type"))
    payroll = plan.fetch("ready").find { |row| row["event_type"] == "income" }
    assert_equal({ "category_id" => nil, "category_name" => nil, "as_before" => false }, payroll.slice("category_id", "category_name", "as_before"))
    ids = plan.fetch("ready_event_ids")
    lines = ->(shown) { ids.map { |id| { event_id: id, decision: "as_read" }.merge(shown.call(id)) } }
    # A request that does not say what she was shown saves nothing.
    approve_lines({ expect_ready_ids: ids, lines: lines.call(->(_id) { {} }) }, source: later)
    assert_response :conflict
    # The old list showed "No category" for this line: approving on that basis is refused, not saved as Dining out.
    approve_lines({ expect_ready_ids: ids, lines: lines.call(->(id) { { shown: { category_id: nil, event_type: plan.fetch("ready").find { |row| row["event_id"] == id }["event_type"] } } }) }, source: later)
    assert_response :conflict
    assert_equal 1, SourceReviewVersion.where(household: @household).count
    # Exactly what was shown saves exactly that.
    approve_lines({ expect_ready_ids: ids, lines: lines.call(->(id) { { shown: plan.fetch("ready").find { |row| row["event_id"] == id }.slice("category_id", "event_type").symbolize_keys } }) }, source: later)
    assert_response :success
    saved = SourceReviewHead.find_by!(financial_source_event_id: later[:revision].financial_source_events.order(:position).first.id).approved_version
    assert_equal dining.id, saved.budget_category_id
  end

  test "a reader guess for an inactive category and a history category she has since archived both read as no category" do
    archived = @household.budget_categories.create!(name: "Old habit", stack_key: "discretionary", sort_order: 2)
    earlier = build_source(rows: [ [ "Zippy's", -1_000, "purchase", 1 ] ])
    approve_lines({ lines: [ { event_id: earlier[:revision].financial_source_events.sole.id, decision: "edited", edit: { kind: "spending", merchant: "Zippy's", posted_on: "2026-07-02", amount_cents: 1_000, category_id: archived.id } } ] }, source: earlier)
    guessed = build_source(rows: [ [ "Corner Cafe", -900, "purchase", 5 ] ])
    @household.transaction_drafts.create!(financial_document_import: guessed[:import], financial_source_event: guessed[:revision].financial_source_events.sole, occurred_on: Date.new(2026, 7, 6), merchant: "Corner Cafe",
      total_amount_cents: 900, budget_category: archived, source_type: "statement", status: "pending")
    archived.update!(active: false)
    later = build_source(rows: [ [ "Zippy's", -700, "purchase", 3 ] ])
    assert_equal [ :no_category ], FinancialDocuments::SourceReview::ParticipantPlan.new(@household, later[:revision]).attention.map(&:kind)
    assert_equal [ :no_category ], FinancialDocuments::SourceReview::ParticipantPlan.new(@household, guessed[:revision]).attention.map(&:kind)
  end

  test "a category that changed between what she saw and her approval is refused with nothing saved" do
    dining = @household.budget_categories.create!(name: "Dining out", stack_key: "discretionary", sort_order: 1)
    shopping = @household.budget_categories.create!(name: "Shopping", stack_key: "discretionary", sort_order: 2)
    edit = ->(category) { { kind: "spending", merchant: "Zippy's", posted_on: "2026-07-02", amount_cents: 1_000, category_id: category.id } }
    first = build_source(rows: [ [ "Zippy's", -1_000, "purchase", 1 ] ])
    approve_lines({ lines: [ { event_id: first[:revision].financial_source_events.sole.id, decision: "edited", edit: edit.call(dining) } ] }, source: first)
    later = build_source(rows: [ [ "Zippy's", -700, "purchase", 3 ] ])
    shown = plan_for(later).fetch("ready").sole
    assert_equal dining.id, shown.fetch("category_id")
    # While the screen was open she chose Shopping for the same merchant somewhere else.
    other = build_source(rows: [ [ "Zippy's", -400, "purchase", 6 ] ])
    approve_lines({ lines: [ { event_id: other[:revision].financial_source_events.sole.id, decision: "edited", edit: edit.call(shopping).merge(amount_cents: 400, posted_on: "2026-07-07") } ] }, source: other)
    assert_response :success
    before = SourceReviewVersion.where(household: @household).count
    approve_lines({ expect_ready_ids: [ shown.fetch("event_id") ], lines: [ { event_id: shown.fetch("event_id"), decision: "as_read", shown: { category_id: dining.id, event_type: "purchase" } } ] }, source: later)
    assert_response :conflict
    assert_match(/look again/i, response.parsed_body.fetch("errors").first)
    assert_equal before, SourceReviewVersion.where(household: @household).count
  end

  test "a retry after a timeout is a no-op even when this statement's own approvals would change the history" do
    dining = @household.budget_categories.create!(name: "Dining out", stack_key: "discretionary", sort_order: 1)
    shopping = @household.budget_categories.create!(name: "Shopping", stack_key: "discretionary", sort_order: 2)
    source = build_source(rows: [ [ "Zippy's", -1_000, "purchase", 1 ], [ "Zippy's", -700, "purchase", 3 ] ])
    first, second = source[:revision].financial_source_events.order(:position).to_a
    [ [ first, dining ], [ second, shopping ] ].each do |event, category|
      @household.transaction_drafts.create!(financial_document_import: source[:import], financial_source_event: event, occurred_on: event.posted_on, merchant: "Zippy's",
        total_amount_cents: event.expense_amount_cents, budget_category: category, source_type: "statement", status: "pending")
    end
    plan = plan_for(source)
    ids = plan.fetch("ready_event_ids")
    assert_equal 2, ids.length
    body = { expect_ready_ids: ids, lines: plan.fetch("ready").map { |row| { event_id: row["event_id"], decision: "as_read", shown: row.slice("category_id", "event_type").symbolize_keys } } }
    approve_lines(body, key: "first-try", source: source)
    assert_response :success
    # The first answer reached the server but the screen never heard back; she tries again.
    approve_lines(body, key: "first-try", source: source)
    assert_response :success
    assert_equal({ "approved" => 0, "left_out" => 0, "unchanged" => 2, "complete" => false }, response.parsed_body.fetch("result"))
    assert_equal [ dining.id, shopping.id ], SourceReviewVersion.where(household: @household).order(:id).pluck(:budget_category_id)
  end

  test "a statement whose lines may be missing asks her, and only her answer is recorded as the attestation" do
    source = build_source(rows: [ [ "Pay 1", 10_000, "income", 1 ], [ "Pay 2", 10_001, "income", 2 ] ], reported: 3)
    plan = plan_for(source)
    assert_equal "Your statement shows 3 lines and we found 2. Is anything missing?", plan.dig("coverage", "question")
    assert_nil plan.dig("coverage", "answer")
    ids = plan.fetch("ready_event_ids")
    lines = plan.fetch("ready").map { |row| { event_id: row["event_id"], decision: "as_read", shown: row.slice("category_id", "event_type").symbolize_keys } }
    # No answer: every line saves, but nothing is said on her behalf about whether lines are missing.
    approve_lines({ expect_ready_ids: ids, lines: lines }, source: source)
    assert_response :success
    assert_equal false, response.parsed_body.dig("result", "complete")
    assert_equal 0, SourceRevisionApproval.where(household: @household).count
    # "Something's missing": recorded as not attested, plainly.
    approve_lines({ lines: [], coverage_answer: "something_missing" }, source: source)
    assert_response :success
    approval = SourceRevisionApproval.where(household: @household).sole
    assert_equal false, approval.coverage_attestation.fetch("all_document_rows_accounted")
    assert_includes approval.deficiencies, "document_rows_not_attested"
    assert_equal "something_missing", plan_for(source).dig("coverage", "answer")
    # Saying the same thing again changes nothing.
    approve_lines({ lines: [], coverage_answer: "something_missing" }, source: source)
    assert_equal 1, SourceRevisionApproval.where(household: @household).count
    # "Nothing's missing": attested, as a new version that supersedes the earlier one.
    approve_lines({ lines: [], coverage_answer: "nothing_missing" }, source: source)
    assert_response :success
    latest = SourceRevisionApproval.where(household: @household).order(:version_number).last
    assert_equal 2, latest.version_number
    assert_equal true, latest.coverage_attestation.fetch("all_document_rows_accounted")
    assert_not_includes latest.deficiencies, "document_rows_not_attested"
    assert_equal "nothing_missing", plan_for(source).dig("coverage", "answer")
  end

  test "a statement that reconciles needs no question" do
    source = build_source(rows: [ [ "Pay 1", 10_000, "income", 1 ] ], account: { opening_balance_cents: 0, closing_balance_cents: 10_000, printed_debit_cents: 0, printed_credit_cents: 10_000, printed_row_count: 1, period_start_on: "2026-07-01", period_end_on: "2026-07-31" })
    assert_equal "matches", FinancialDocuments::SourceReview::CoverageQuestion.totals_check(source[:revision])
    plan = plan_for(source)
    assert_nil plan.dig("coverage", "question")
    approve_lines({ expect_ready_ids: plan.fetch("ready_event_ids"), lines: plan.fetch("ready").map { |row| { event_id: row["event_id"], decision: "as_read", shown: row.slice("category_id", "event_type").symbolize_keys } } }, source: source)
    assert_response :success
    assert_equal true, response.parsed_body.dig("result", "complete")
    assert_equal true, SourceRevisionApproval.where(household: @household).sole.coverage_attestation.fetch("all_document_rows_accounted")
  end

  test "saying Yes to Still Dining out keeps what kind of line it is" do
    dining = @household.budget_categories.create!(name: "Dining out", stack_key: "discretionary", sort_order: 1)
    shopping = @household.budget_categories.create!(name: "Shopping", stack_key: "discretionary", sort_order: 2)
    first = build_source(rows: [ [ "Zippy's", -1_000, "purchase", 1 ] ])
    approve_lines({ lines: [ { event_id: first[:revision].financial_source_events.sole.id, decision: "edited", edit: { kind: "spending", merchant: "Zippy's", posted_on: "2026-07-02", amount_cents: 1_000, category_id: dining.id } } ] }, source: first)
    later = build_source(rows: [ [ "Zippy's late fee", -700, "fee", 3 ] ])
    event = later[:revision].financial_source_events.sole
    event.financial_source_evidence.update!(payload: event.financial_source_evidence.payload.merge("merchant" => "Zippy's"))
    @household.transaction_drafts.create!(financial_document_import: later[:import], financial_source_event: event, occurred_on: event.posted_on, merchant: "Zippy's",
      total_amount_cents: 700, budget_category: shopping, source_type: "statement", status: "pending")
    line = plan_for(later).fetch("attention").sole
    assert_equal [ "still_category", "Still Dining out?" ], line.values_at("kind", "question")
    approve_lines({ lines: [ { event_id: event.id, decision: "as_read", shown: { category_id: dining.id, event_type: "fee" } } ] }, source: later)
    assert_response :success
    version = SourceReviewHead.find_by!(financial_source_event_id: event.id).approved_version
    assert_equal [ "fee", dining.id ], [ version.event_type, version.budget_category_id ]
    assert_equal 700, @household.household_transactions.where(financial_source_event: event).sole.total_amount_cents
    # Answering about a category she was not shown is refused.
    other = build_source(rows: [ [ "Zippy's late fee", -600, "fee", 4 ] ])
    other_event = other[:revision].financial_source_events.sole
    other_event.financial_source_evidence.update!(payload: other_event.financial_source_evidence.payload.merge("merchant" => "Zippy's"))
    @household.transaction_drafts.create!(financial_document_import: other[:import], financial_source_event: other_event, occurred_on: other_event.posted_on, merchant: "Zippy's",
      total_amount_cents: 600, budget_category: shopping, source_type: "statement", status: "pending")
    approve_lines({ lines: [ { event_id: other_event.id, decision: "as_read", shown: { category_id: shopping.id, event_type: "fee" } } ] }, source: other)
    assert_response :conflict
  end

  test "choosing a category for a fee or interest line keeps it a fee or interest, not a purchase" do
    source = build_source(rows: [ [ "Late fee", -300, "fee", 1 ], [ "Interest charge", -120, "interest", 2 ] ])
    source[:revision].financial_source_events.order(:position).each do |event|
      approve_lines({ lines: [ { event_id: event.id, decision: "edited", edit: { kind: "spending", merchant: merchant_of(event), posted_on: event.posted_on.iso8601, amount_cents: event.signed_amount_cents.abs, category_id: @groceries.id } } ] }, source: source)
      assert_response :success
    end
    assert_equal %w[fee interest], SourceReviewVersion.where(household: @household).order(:id).pluck(:event_type)
    assert_equal [ 300, 120 ], @household.household_transactions.order(:id).pluck(:total_amount_cents)
  end

  test "two unnamed accounts stay two accounts, so a charge in one is never offered as a duplicate of the other" do
    source = build_source(rows: [ [ "Payless", -1_000, "purchase", 1, "first" ], [ "Payless", -1_000, "purchase", 1, "second" ] ], label: "Spreadsheet account")
    ids = source[:revision].financial_source_events.order(:position).ids
    approve_lines({ lines: ids.map { |id| { event_id: id, decision: "leave_out" } } }, source: source)
    assert_response :success
    assert_equal 2, SourceTrackedAccount.where(household: @household).count
    # A name she gives is still reused, so the same real account on the next statement is one account.
    named = build_source(rows: [ [ "Ross", -500, "purchase", 2 ] ])
    approve_lines({ lines: [], accounts: [ { source_account_id: named[:revision].financial_source_accounts.sole.id, account_basis: "asset", label: "Bank of Guam checking" } ] }, source: named)
    again = build_source(rows: [ [ "Ross", -700, "purchase", 3 ] ])
    approve_lines({ lines: [], accounts: [ { source_account_id: again[:revision].financial_source_accounts.sole.id, account_basis: "asset", label: "Bank of Guam checking" } ] }, source: again)
    assert_equal 3, SourceTrackedAccount.where(household: @household).count
  end

  # LockWaitSwitch stands in for Postgres timing out on the lock; the SQL assertion below checks the bounded wait is really asked for.
  test "a page that waits too long for the household lock saves nothing and says so" do
    lines = as_read([ @events.fetch("Payroll").id ])
    LockWaitSwitch.on = true
    statements = []
    watcher = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
    begin
      approve_lines({ lines: lines })
    ensure
      LockWaitSwitch.on = false
      ActiveSupport::Notifications.unsubscribe(watcher)
    end
    assert_response :conflict
    assert_match(/Nothing was saved\. Try again/, response.parsed_body.fetch("errors").first)
    assert_equal 0, SourceReviewVersion.where(household: @household).count
    assert_includes statements, "SET LOCAL lock_timeout = '5s'"
  end

  test "every answer that saves a line as the statement reads it must say what she was shown, whether or not the request names the lines it expects" do
    payroll, payless = @events.fetch("Payroll"), @events.fetch("Payless")
    shown = as_read([ payroll.id, payless.id ])
    [ shown.map { |entry| entry.except(:shown) }, [ shown.first, shown.last.except(:shown) ], [ shown.first.merge(shown: { category_id: nil }) ],
      [ shown.first, shown.last.merge(shown: { category_id: nil, event_type: "purchase" }) ] ].each do |lines|
      approve_lines({ lines: lines })
      assert_response :conflict
      assert_match(/look again/i, response.parsed_body.fetch("errors").first)
    end
    assert_equal 0, SourceReviewVersion.where(household: @household).count
    approve_lines({ lines: shown })
    assert_response :success
    assert_equal [ nil, @groceries.id ], [ payroll, payless ].map { |event| SourceReviewHead.find_by!(financial_source_event_id: event.id).approved_version.budget_category_id }
  end

  test "different charge must also say what she was shown" do
    approve_lines({ lines: as_read(review_plan.fetch("ready_event_ids")) })
    copy = build_source(rows: [ [ "Payless", -1_000, "purchase", 2 ] ], account: { period_start_on: "2026-07-01", period_end_on: "2026-07-31" })
    line = plan_for(copy).fetch("attention").sole
    assert_equal "duplicate", line.fetch("kind")
    event_id = line.fetch("event_id")
    approve_lines({ lines: [ { event_id: event_id, decision: "different" } ] }, source: copy)
    assert_response :conflict
    approve_lines({ lines: [ { event_id: event_id, decision: "different", shown: { category_id: nil, event_type: "refund" } } ] }, source: copy)
    assert_response :conflict
    assert_equal 0, SourceReviewHead.where(financial_source_event_id: event_id).count
    approve_lines({ lines: [ { event_id: event_id, decision: "different", shown: line.slice("category_id", "event_type").symbolize_keys } ] }, source: copy)
    assert_response :success
    assert_equal "distinct", SourceReviewHead.find_by!(financial_source_event_id: event_id).approved_version.overlap_disposition
  end

  test "saying something is missing is recorded even when the totals no longer disagree with the lines she has saved, and saving again does not fail" do
    statement = { opening_balance_cents: 0, closing_balance_cents: 10_000, printed_debit_cents: 0, printed_credit_cents: 10_000, period_start_on: "2026-07-01", period_end_on: "2026-07-31" }
    source = build_source(rows: [ [ "Pay 1", 9_000, "income", 1 ] ], account: statement)
    assert_equal "mismatch", FinancialDocuments::SourceReview::CoverageQuestion.totals_check(source[:revision])
    event_id = source[:revision].financial_source_events.sole.id
    fixed = { event_id: event_id, decision: "edited", edit: { kind: "money_in", merchant: "Pay 1", posted_on: "2026-07-02", amount_cents: 10_000 } }
    approve_lines({ lines: [ fixed ], coverage_answer: "something_missing" }, source: source)
    assert_response :success
    approval = SourceRevisionApproval.where(household: @household).sole
    assert_equal [ "qualified", false ], [ approval.coverage_status, approval.coverage_attestation.fetch("all_document_rows_accounted") ]
    assert_empty approval.deficiencies - %w[document_rows_not_attested account_period_or_row_coverage_not_attested]
    # Saying it again, or changing her mind, never fails.
    approve_lines({ lines: [], coverage_answer: "something_missing" }, source: source)
    assert_response :success
    approve_lines({ lines: [], coverage_answer: "nothing_missing" }, source: source)
    assert_response :success
    assert_equal "complete", SourceRevisionApproval.where(household: @household).order(:version_number).last.coverage_status
  end

  test "the same account on the next statement is the same account, so an overlapping charge is still asked about" do
    first = build_source(rows: [ [ "Payroll", 5_000, "income", 2 ] ], label: "BOG Everyday Checking")
    approve_lines({ lines: as_read(first[:revision].financial_source_events.ids, source: first) }, source: first)
    assert_response :success, response.body
    second = build_source(rows: [ [ "Payroll", 5_000, "income", 2 ], [ "Bonus", 700, "income", 9 ] ], label: "bog  everyday checking")
    duplicate = plan_for(second).fetch("attention").find { |row| row["kind"] == "duplicate" }
    assert duplicate, "the copy is asked about before she answers"
    # Answering it is not refused by the account linking: the question is the same one before and after.
    approve_lines({ lines: [ { event_id: duplicate.fetch("event_id"), decision: "different", shown: duplicate.slice("category_id", "event_type").symbolize_keys } ] }, source: second)
    assert_response :success, response.body
    assert_equal 1, SourceTrackedAccount.where(household: @household).count
    assert_equal "BOG Everyday Checking", SourceTrackedAccount.where(household: @household).sole.label
    assert_equal 2, SourceAccountIdentityVersion.where(household: @household).count
  end

  test "linking a statement's account while she answers a copy question never makes her answer stale" do
    first = build_source(rows: [ [ "Payroll", 5_000, "income", 2 ] ], label: "BOG Everyday Checking")
    approve_lines({ lines: as_read(first[:revision].financial_source_events.ids, source: first) }, source: first)
    assert_response :success, response.body
    # A different, named account has the same charge on the same day. She is asked, as before the link; "Different charge" is honoured
    # even though linking leaves this a different account, instead of a refusal she can never get past.
    second = build_source(rows: [ [ "Payroll", 5_000, "income", 2 ] ], label: "BOG Savings")
    question = plan_for(second).fetch("attention").sole
    assert_equal "duplicate", question.fetch("kind")
    2.times do
      approve_lines({ lines: [ { event_id: question.fetch("event_id"), decision: "different", shown: question.slice("category_id", "event_type").symbolize_keys } ] }, source: second)
      assert_response :success, response.body
    end
    assert_equal 2, SourceTrackedAccount.where(household: @household).count
  end

  test "two files that only say bank account stay two accounts" do
    one = build_source(rows: [ [ "Payless", -1_000, "purchase", 2 ] ], label: "Bank account")
    two = build_source(rows: [ [ "Payless", -1_000, "purchase", 2 ] ], label: "Bank account")
    [ one, two ].each do |source|
      approve_lines({ lines: source[:revision].financial_source_events.ids.map { |id| { event_id: id, decision: "leave_out" } } }, source: source)
      assert_response :success
    end
    assert_equal 2, SourceTrackedAccount.where(household: @household).count
  end

  test "changing only the dates of one of two generic accounts never merges it into the other, so their charges are not offered as copies of each other" do
    one = build_source(rows: [ [ "Pay", 5_000, "income", 2 ] ], label: "Bank account")
    approve_lines({ lines: as_read(one[:revision].financial_source_events.ids, source: one) }, source: one)
    assert_response :success, response.body
    two = build_source(rows: [ [ "Pay", 5_000, "income", 2 ] ], label: "Bank account")
    question = plan_for(two).fetch("attention").sole
    approve_lines({ lines: [ { event_id: question.fetch("event_id"), decision: "different", shown: question.slice("category_id", "event_type").symbolize_keys } ] }, source: two)
    assert_response :success, response.body
    assert_equal 2, SourceTrackedAccount.where(household: @household).count
    account = two[:revision].financial_source_accounts.sole
    approve_lines({ lines: [], accounts: [ { source_account_id: account.id, period_start_on: "2026-07-01", period_end_on: "2026-07-31" } ] }, source: two)
    assert_response :success, response.body
    tracked = SourceAccountReviewHead.where(household: @household).map { |head| head.approved_version.source_tracked_account_id }
    assert_equal 2, tracked.uniq.length, "each account stays its own"
    assert_equal 2, SourceTrackedAccount.where(household: @household).count
    assert_empty plan_for(two).fetch("attention").select { |row| row["kind"] == "duplicate" }
  end

  test "an older line she edited is compared by what she approved, so a copy of the edited line is asked about and the rest can be approved" do
    first = build_source(rows: [ [ "Pay", 7_000, "income", 2 ] ], label: "BOG Everyday Checking")
    older = first[:revision].financial_source_events.sole
    approve_lines({ lines: [ { event_id: older.id, decision: "edited", edit: { kind: "money_in", amount_cents: 5_000 } } ] }, source: first)
    assert_response :success, response.body
    second = build_source(rows: [ [ "Pay", 5_000, "income", 2 ], [ "Bonus", 700, "income", 9 ] ], label: "BOG Everyday Checking")
    plan = plan_for(second)
    copy = plan.fetch("attention").find { |row| row["kind"] == "duplicate" }
    assert copy, "the copy of the edited line is asked about before she approves the rest"
    bonus = second[:revision].financial_source_events.order(:position).last
    assert_equal [ bonus.id ], plan.fetch("ready_event_ids")
    approve_lines({ expect_ready_ids: plan.fetch("ready_event_ids"), lines: as_read(plan.fetch("ready_event_ids"), source: second) }, source: second)
    assert_response :success, response.body
    approve_lines({ lines: [ { event_id: copy.fetch("event_id"), decision: "leave_out" } ] }, source: second)
    assert_response :success, response.body
  end

  test "the same file and row is asked about as a copy even when every amount differs" do
    checksum = SecureRandom.hex(32)
    first = build_source(rows: [ [ "Pay", 7_000, "income", 2 ] ], label: "BOG Everyday Checking", checksum: checksum)
    older = first[:revision].financial_source_events.sole
    approve_lines({ lines: [ { event_id: older.id, decision: "edited", edit: { kind: "money_in", amount_cents: 5_000 } } ] }, source: first)
    assert_response :success, response.body
    # The same file read again gives a third amount for the same physical row: no amount or date key matches it, but the
    # detector treats file + row as a strong copy, so the plan must ask instead of showing it as ready.
    second = build_source(rows: [ [ "Pay", 6_000, "income", 2 ], [ "Bonus", 700, "income", 9 ] ], label: "BOG Everyday Checking", checksum: checksum)
    plan = plan_for(second)
    copy = plan.fetch("attention").find { |row| row["kind"] == "duplicate" }
    assert copy, "the same file and row is asked about before she approves the rest"
    bonus = second[:revision].financial_source_events.order(:position).last
    assert_equal [ bonus.id ], plan.fetch("ready_event_ids")
    approve_lines({ expect_ready_ids: plan.fetch("ready_event_ids"), lines: as_read(plan.fetch("ready_event_ids"), source: second) }, source: second)
    assert_response :success, response.body
  end

  test "a copy of a line whose edit is still waiting as a draft is asked about too" do
    first = build_source(rows: [ [ "Pay", 7_000, "income", 2 ] ], label: "BOG Everyday Checking")
    older = first[:revision].financial_source_events.sole
    # An edit she has not approved yet still says what that line will be.
    head = SourceReviewHead.create!(household: @household, financial_source_event: older)
    SourceReviewDraft.create!(household: @household, source_review_head: head, staged_by_user: @user, base_head_lock_version: head.lock_version, digest: SecureRandom.hex(32), reason: "test",
      facts: { "signed_amount_cents" => 5_000, "posted_on" => older.posted_on.iso8601 })
    second = build_source(rows: [ [ "Pay", 5_000, "income", 2 ] ], label: "BOG Everyday Checking")
    assert_equal [ "duplicate" ], plan_for(second).fetch("attention").pluck("kind")
  end

  test "a name or a saved description with a raw account number reads masked, even when it was approved before" do
    names = ->(label, masked = nil) { FinancialDocuments::SourceReview::AccountName.parts(label, masked) }
    assert_equal({ name: "Bank of Guam checking ····5678", last4: nil }, names.call("Bank of Guam checking 000012345678"))
    assert_equal({ name: "Statement.pdf ····5678", last4: "1234" }, names.call("Statement.pdf 12345678 · ****1234"))
    event = @events.fetch("Payless")
    approve_lines({ lines: as_read([ event.id ]) })
    version = SourceReviewHead.find_by!(financial_source_event_id: event.id).approved_version
    # Rows approved before descriptions were masked hold the statement's words; the table normally refuses edits, so lift that for this one setup.
    SourceReviewVersion.connection.execute("ALTER TABLE source_review_versions DISABLE TRIGGER USER")
    SourceReviewVersion.where(id: version.id).update_all(merchant: "Payless 00002468 store")
    get "/api/v1/document_imports/#{@source[:import].id}/source_review", params: { revision_id: @source[:revision].id }, headers: headers
    shown = response.parsed_body.dig("source_review", "participant_review", "rows", event.id.to_s, "approved", "facts", "merchant")
    assert_equal "Payless ····2468 store", shown
    assert_equal "Payless 00002468 store", version.reload.merchant
  end

  test "looking up what she chose before only reads the merchants on this statement" do
    dining = @household.budget_categories.create!(name: "Dining out", stack_key: "discretionary", sort_order: 1)
    20.times do |index|
      other = build_source(rows: [ [ "Unrelated shop #{index}", -(100 + index), "purchase", index + 8 ] ])
      approve_lines({ lines: [ { event_id: other[:revision].financial_source_events.sole.id, decision: "edited", edit: { kind: "spending", merchant: "Unrelated shop #{index}", posted_on: other[:revision].financial_source_events.sole.posted_on.iso8601, amount_cents: 100 + index, category_id: dining.id } } ] }, source: other)
    end
    later = build_source(rows: [ [ "Zippy's", -700, "purchase", 3 ] ])
    seen = []
    normalizer = FinancialDocuments::MerchantNormalizer.method(:call)
    FinancialDocuments::MerchantNormalizer.singleton_class.send(:define_method, :call) { |value| seen << value.to_s; normalizer.call(value) }
    begin
      FinancialDocuments::SourceReview::ParticipantPlan.new(@household, later[:revision]).lines
    ensure
      FinancialDocuments::MerchantNormalizer.singleton_class.send(:define_method, :call, &normalizer)
    end
    assert_empty(seen.grep(/Unrelated shop/))
  end

  test "a statement uploaded twice is checked for copies with a fixed number of queries, not a handful per line" do
    rows = (1..40).map { |index| [ "Pay #{index}", 10_000 + index, "income", index ] }
    first = build_source(rows: rows)
    ids = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, first[:revision]).ready_ids
    ids.each_slice(20) { |slice| approve_lines({ expect_ready_ids: slice, paged: true, lines: as_read(slice, source: first) }, source: first) }
    assert_response :success
    copy = build_source(rows: rows)
    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    plan = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { FinancialDocuments::SourceReview::ParticipantPlan.new(@household, copy[:revision]).tap(&:lines) }
    assert_equal [ :duplicate ] * 40, plan.lines.map(&:kind)
    assert_operator queries, :<, 80, "#{queries} queries for 40 lines that all overlap an earlier statement"
  end

  test "a page reads the household's lines once, not once per line, and a repeat of the page still saves nothing new" do
    rows = (1..20).map { |index| [ "Pay #{index}", 10_000 + index, "income", index ] }
    long = build_source(rows: rows)
    ids = FinancialDocuments::SourceReview::ParticipantPlan.new(@household, long[:revision]).ready_ids
    reads = 0
    counter = ->(*, payload) { reads += 1 if payload[:sql].match?(/\ASELECT "financial_source_events"\.\* FROM "financial_source_events" WHERE "financial_source_events"\."household_id" = \$1\z/) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { approve_lines({ expect_ready_ids: ids, paged: true, lines: as_read(ids, source: long) }, source: long) }
    assert_response :success, response.body
    assert_equal 20, response.parsed_body.dig("result", "approved")
    assert_operator reads, :<=, 4, "#{reads} reads of the household's lines for 20 lines"
    approve_lines({ expect_ready_ids: ids, paged: true, lines: as_read(ids, source: long) }, source: long)
    assert_equal({ "approved" => 0, "left_out" => 0, "unchanged" => 20, "complete" => false }, response.parsed_body.fetch("result"))
  end

  test "the approval page is 100 lines" do
    assert_equal 100, FinancialDocuments::SourceReview::LineApprover::MAX_LINES
  end

  test "challenge first review creates private everyday choices once without building a budget" do
    with_budgetless_challenge do
      2.times { review_plan }
      assert_equal [ [ "Bills & essentials", "non_discretionary" ], [ "Everyday spending", "discretionary" ] ], @household.budget_categories.order(:name).pluck(:name, :stack_key)
      assert_empty @household.budget_years
      executions = @household.household_operation_executions.where(operation_key: "savings.daily.category.create")
      assert_equal 2, executions.count
      assert executions.all? { |execution| execution.normalized_input.empty? && execution.after_snapshot.empty? }
      assert_empty @household.household_transactions
    end
  end

  test "challenge merchant suggestions wait for explicit one tap approval then patterns find Ross and Kmart" do
    with_budgetless_challenge do
      @source = build_source(rows: [ [ "Ross", -12000, "purchase", 1 ], [ "Kmart", -9000, "purchase", 2 ], [ "GPA power", -18000, "purchase", 3 ], [ "Mystery shop", -500, "purchase", 4 ] ])
      plan = review_plan
      rows = (plan.fetch("ready") + plan.fetch("attention")).index_by { |row| row.fetch("merchant") }
      assert_equal "Everyday spending", rows.fetch("Ross").fetch("category_name")
      assert_equal "Everyday spending", rows.fetch("Kmart").fetch("category_name")
      assert_equal "Bills & essentials", rows.fetch("GPA power").fetch("category_name")
      assert_nil rows.fetch("Mystery shop").fetch("category_id")
      assert_equal 3, plan.fetch("ready").length
      assert_empty @household.household_transactions
      assert_nil SourceReviewHead.find_by(financial_source_event_id: rows.fetch("Ross").fetch("event_id"))
      %w[Ross Kmart].each do |name|
        row = rows.fetch(name)
        approve_lines({ lines: [ { event_id: row.fetch("event_id"), decision: "as_read", shown: row.slice("event_type", "category_id") } ] })
        assert_response :success, response.body
      end
      patterns = SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 4)).call
      assert_equal %w[Ross Kmart], patterns.fetch(:discretionary_merchants).pluck(:label)
      assert_equal [ 12000, 9000 ], patterns.fetch(:discretionary_merchants).pluck(:total_cents)
    end
  end

  test "challenge bill and everyday hints are defaults and preserve earlier approved choices" do
    with_budgetless_challenge do
      bills = [ "Rent", "GPA power", "GWA water", "GTA internet", "Docomo phone", "Payless Supermarkets", "Cost-U-Less", "Shell", "Mobil", "Monthly service fee" ]
      everyday = [ "Ross", "Kmart", "Jamba", "McDonald's", "Port of Mocha", "Amazon", "Netflix monthly subscription", "Restaurant (includes tip)" ]
      @source = build_source(rows: (bills + everyday).each_with_index.map { |name, i| [ name, -1000 - i, "purchase", i + 1 ] })
      rows = review_plan.fetch("ready")
      assert_equal bills + everyday, rows.pluck("merchant")
      rows.each do |row|
        assert_equal(bills.include?(row.fetch("merchant")) ? "Bills & essentials" : "Everyday spending", row.fetch("category_name"))
      end
      assert_empty @household.household_transactions
      ross = rows.find { |row| row["merchant"] == "Ross" }
      bills_id = @household.budget_categories.find_by!(name: "Bills & essentials").id
      approve_lines({ lines: [ { event_id: ross.fetch("event_id"), decision: "edited", edit: { kind: "spending", category_id: bills_id } } ] })
      assert_response :success
      @source = build_source(rows: [ [ "Ross", -1500, "purchase", 15 ] ])
      row = review_plan.fetch("attention").sole
      assert_equal "still_category", row.fetch("kind")
      assert_equal bills_id, row.fetch("category_id")
    end
  end

  test "one tap confirmation of a statement refund nets the merchant in patterns" do
    with_budgetless_challenge do
      @source = build_source(rows: [ [ "Ross", -5525, "purchase", 1 ], [ "Kmart", -3175, "purchase", 2 ], [ "Amazon Marketplace", -3899, "purchase", 3 ], [ "Amazon refund order DEMO-8001", 1299, "refund", 4 ] ])
      rows = (review_plan.fetch("ready") + review_plan.fetch("attention")).index_by { |row| row.fetch("merchant") }
      [ "Ross", "Kmart", "Amazon Marketplace" ].each do |name|
        row = rows.fetch(name)
        approve_lines({ lines: [ { event_id: row.fetch("event_id"), decision: "as_read", shown: row.slice("event_type", "category_id") } ] })
        assert_response :success, response.body
      end
      analyze = -> { SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 4)).call }
      assert_equal [ "Ross", "Amazon Marketplace", "Kmart" ], analyze.call[:discretionary_merchants].pluck(:label)
      row = rows.fetch("Amazon refund order DEMO-8001")
      assert_equal "refund", row.fetch("kind")
      approve_lines({ lines: [ { event_id: row.fetch("event_id"), decision: "as_read", shown: row.slice("event_type", "category_id") } ] })
      assert_response :success, response.body
      assert_equal [ "Ross", "Kmart", "Amazon Marketplace" ], analyze.call[:discretionary_merchants].pluck(:label)
      assert_equal [ 5525, 3175, 2600 ], analyze.call[:discretionary_merchants].pluck(:total_cents)
    end
  end

  test "challenge lines previously saved without a category can be corrected and counted" do
    with_budgetless_challenge do
      @source = build_source(rows: [ [ "Ross", -12000, "purchase", 1 ] ])
      event = @source[:revision].financial_source_events.sole
      approve_lines({ lines: [ { event_id: event.id, decision: "edited", edit: { kind: "spending", category_id: nil } } ] })
      assert_response :success
      assert_empty @household.household_transactions
      review_plan
      category = @household.budget_categories.find_by!(name: "Everyday spending")
      head = SourceReviewHead.find_by!(financial_source_event_id: event.id)
      approve_lines({ lines: [ { event_id: event.id, expected_head: { approved_version_id: head.approved_version_id, lock_version: head.lock_version }, decision: "edited", edit: { kind: "spending", category_id: category.id } } ] })
      assert_response :success, response.body
      assert_equal 12000, @household.household_transactions.sole.total_amount_cents
      assert_equal [ "Ross" ], SpendingPatterns::Analyzer.new(@household, today: Date.new(2026, 11, 4)).call.fetch(:discretionary_merchants).pluck(:label)
    end
  end

  private

  def with_budgetless_challenge
    travel_to Time.utc(2026, 11, 4, 2)
    setup_savings_context
    @user, @household = @savings_user, @savings_household
    with_savings_runtime do
      savings_enroll
      assert_empty @household.budget_categories
      @source = build_source
      yield
    end
  ensure
    travel_back
  end

  def with_page_limit(count)
    approver = FinancialDocuments::SourceReview::LineApprover
    approver.send(:remove_const, :MAX_LINES)
    approver.const_set(:MAX_LINES, count)
    yield
  ensure
    approver.send(:remove_const, :MAX_LINES)
    approver.const_set(:MAX_LINES, 100)
  end

  def headers = { "Authorization" => "Bearer test_token_#{@user.id}" }

  def approve_lines(input, key: SecureRandom.uuid, source: @source)
    post "/api/v1/document_imports/#{source[:import].id}/review/approve_lines", params: { revision_id: source[:revision].id, input: input }, headers: headers.merge("Idempotency-Key" => key), as: :json
  end

  # The lines exactly as her screen sent them: what she was shown for each, taken from the plan.
  def as_read(ids, source: @source)
    plan = plan_for(source)
    shown = (plan.fetch("ready") + plan.fetch("attention")).index_by { |row| row["event_id"] }
    ids.map { |id| { event_id: id, decision: "as_read" }.merge(shown[id] ? { shown: shown[id].slice("category_id", "event_type").symbolize_keys } : {}) }
  end

  def plan_for(source)
    get "/api/v1/document_imports/#{source[:import].id}/source_review", params: { revision_id: source[:revision].id }, headers: headers
    assert_response :success
    response.parsed_body.dig("source_review", "participant_review", "plan")
  end

  def review_plan
    get "/api/v1/document_imports/#{@source[:import].id}/source_review", params: { revision_id: @source[:revision].id }, headers: headers
    assert_response :success
    response.parsed_body.dig("source_review", "participant_review", "plan")
  end

  def merchant_of(event) = event.financial_source_evidence.payload["merchant"]

  def suggest(event, category)
    @household.transaction_drafts.create!(financial_document_import: @source[:import], financial_source_event: event, occurred_on: event.posted_on, merchant: merchant_of(event),
      total_amount_cents: event.expense_amount_cents, budget_category: category, source_type: "statement", status: "pending")
  end

  DEFAULT_ROWS = [ [ "Payroll", 200_000, "income", 1 ], [ "Payless", -1_000, "purchase", 2 ], [ "Ross", -500, "purchase", 3 ], [ "Own savings", -3_000, "transfer", 4 ], [ "Unreadable", nil, "purchase", 5 ] ].freeze

  def build_source(basis: "asset", rows: DEFAULT_ROWS, label: "Spreadsheet account", reported: nil, account: {}, checksum: SecureRandom.hex(32))
    document = FinancialDocumentImport.create!(household: @household, uploaded_by_user: @user, document_kind: "statement", status: "needs_review", filename: "synthetic.csv", content_type: "text/csv", byte_size: 10, s3_key: "synthetic/#{SecureRandom.hex(8)}.csv", checksum_sha256: checksum)
    attempt = document.attempts.create!(provider: "synthetic", model: "synthetic", prompt_version: "synthetic-v1", schema_version: 2, status: "processing", started_at: Time.current)
    events = rows.map do |name, cents, type, row, key|
      { account_key: key || "synthetic-account", row_kind: "posted", event_type: type, signed_amount_cents: cents, posted_on: (Date.new(2026, 7, 2) + ((row - 1) % 28)).iso8601, merchant: name, locator: { page: 1, row: row } }
    end
    accounting = FinancialDocuments::AccountingContract.normalize({ contract_version: FinancialDocuments::AccountingContract::VERSION,
      accounts: (rows.filter_map { |row| row[4] }.uniq.presence || [ "synthetic-account" ]).map { |key| { account_key: key, account_basis: basis, label: label }.merge(account) },
      events: events, reported_row_count: reported || events.length }, coverage: { expected_page_count: 1, processed_pages: [ 1 ] })
    result = FinancialDocuments::SourceAccountingPersister.new(document, attempt: attempt, accounting: accounting).call
    document.update!(metadata: { "source_accounting_revision_id" => result[:revision].id, "source_accounting_review_pending" => true })
    result.merge(import: document)
  end
end
