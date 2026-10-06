module FinancialBaselines
  class Preview
    CALCULATION_VERSION = "approved_spending_baseline_v1"
    SAMPLE_LIMIT = 50

    def initialize(household, user: nil)
      @household, @user = household, user
    end

    def call(raw)
      ApplicationRecord.transaction do
        household.lock!
        FinancialDocuments::SourceReview::Domain.new(household, user: user).authorize!
        calculate(Request.new(household).call(raw))
      end
    end

    def self.presentation(preview)
      preview.except(:rows).merge(sample_rows: preview.fetch(:rows).first(SAMPLE_LIMIT), sample_limit: SAMPLE_LIMIT,
        represented_row_count: preview.fetch(:rows).length, aggregates_use_full_window: true)
    end

    private

    attr_reader :household, :user, :request, :start_on, :end_on, :source, :deficiencies

    def calculate(input)
      @request = input
      @start_on, @end_on = Date.iso8601(input[:window_start_on]), Date.iso8601(input[:window_end_on])
      @deficiencies = []
      @source = FinancialDocuments::SourceReview::ApprovedSourceReader.new(household).call(current_financial_picture: true, revision_ids: input[:revision_ids])
      source[:revisions].each do |revision|
        deficiencies << "source_coverage_not_complete:#{revision[:id]}" unless revision[:participant_approved] && revision[:coverage_status] == "complete"
      end
      source_rows = source[:canonical_rows].map { |row| source_row(row) }
      selected = source_rows.select { |row| in_window?(row[:posted_on]) }
      selected.each do |row|
        deficiencies << "source_account_outside_declared_scope:#{row[:tracked_account_id]}" unless request[:tracked_account_ids].include?(row[:tracked_account_id])
        deficiencies << "stale_source_account_identity:#{row[:source_review_version_id]}" unless row[:account_identity_current]
        deficiencies << "split_funding_unresolved:#{row[:source_review_version_id]}" if row[:requires_funding_link]
      end
      actuals, actual_snapshots = actual_rows(selected)
      rows = selected + actuals
      raise ArgumentError, "This baseline exceeds the bounded 20,000-row review window" if rows.length > 20_000
      overlaps = overlap_warnings(rows)
      deficiencies.concat(overlaps.map { |row| "ambiguous_actual_overlap:#{row[:actual_id]}" })
      account_coverage = coverage
      validate_known_accounts!
      deficiencies << "household_account_scope_not_attested" unless request[:household_scope_attested]
      deficiencies << "missing_accounts_declared" if request[:missing_accounts].any?
      deficiencies << "cash_coverage_unknown_or_partial" unless request[:cash_coverage].in?(%w[complete not_used])
      deficiencies << "no_approved_observations" if rows.none? { |row| row[:classification] != "unknown" }
      refund_allocations = refunds(rows, source_rows)
      cash = cash_summary(rows)
      eligible = category_rules(rows, refund_allocations)
      patterns = Patterns.new(rows, refund_allocations, eligible).call
      snapshot = { calculation_version: CALCULATION_VERSION, window_start_on: start_on.iso8601, window_end_on: end_on.iso8601,
        window_days: (end_on - start_on).to_i + 1, window_complete_calendar_month_count: full_month_count, supported_complete_calendar_month_count: deficiencies.empty? ? full_month_count : 0,
        request: request, rows: rows.sort_by { |row| [ row[:posted_on].to_s, row[:key] ] }, actual_snapshots: actual_snapshots,
        category_eligibility: eligible, source_digest: source[:digest], source_revisions: pinned_source_revisions,
        requested_revision_ids: source[:requested_revision_ids], dependency_revision_ids: source[:dependency_revision_ids],
        source_economic_groups: source[:economic_groups], account_coverage: account_coverage,
        refund_allocations: refund_allocations, cash: cash, patterns: patterns, possible_overlaps: overlaps,
        deficiencies: deficiencies.uniq.sort, complete_eligible: deficiencies.empty?, observed_spending_known: rows.any? { |row| row[:classification] != "unknown" },
        assumptions: [ "Participant-reviewed category eligibility; merchant names do not establish necessity or optional spending.",
          "Frequency and monthly observations do not establish future recurrence or saved cash.",
          "Refunds follow reviewed allocation and posted-window timing; prior-window reversals are identified separately.",
          "Cash withdrawals are movements. Unallocated withdrawals are not savings or proof of a cash balance.",
          "Coverage describes the selected window and declared accounts; manual or partial approval is explicitly limited." ] }
      snapshot.merge(digest: HouseholdFinance::Operations::PreparedOperation.fingerprint(snapshot))
    end

    def pinned_source_revisions
      source[:revisions].map do |revision|
        revision.deep_dup.tap { |copy| copy[:state].delete(:pending_corrections) }
      end
    end

    def source_row(row)
      { key: "source:#{row[:id]}", source_review_version_id: row[:id], source_digest: row[:digest], revision_id: row[:revision_id],
        account_identity_version_id: row[:account_identity_version_id], tracked_account_id: row[:tracked_account_id], account_basis: row[:account_basis],
        account_identity_current: row[:account_identity_current], classification: row[:event_type], signed_amount_cents: row[:signed_amount_cents],
        purchase_amount_cents: row[:purchase_amount_cents], posted_on: row[:posted_on], authorized_on: row[:authorized_on], merchant: row[:merchant],
        expense: row[:spending_eligible], requires_funding_link: row[:requires_funding_link], source_type: "reviewed_source",
        splits: row[:purchase_amount_cents] ? [ { budget_category_id: row[:category][:id] || row[:category]["id"], amount_cents: row[:purchase_amount_cents] } ] : [] }
    end

    def actual_rows(source_rows)
      decisions = request[:actual_decisions].index_by { |row| row[:transaction_id] }
      records = household.household_transactions.where(status: %w[confirmed reconciled], occurred_on: start_on..end_on).includes(transaction_splits: :budget_category).order(:id).to_a
      selected_event_ids = SourceReviewVersion.where(household: household, id: source_rows.pluck(:source_review_version_id).compact).joins(:source_review_head).pluck("source_review_heads.financial_source_event_id")
      snapshots = records.map { |record| { id: record.id, digest: actual_digest(record), source_type: record.source_type } }
      rows = records.filter_map do |record|
        if record.financial_source_event_id
          deficiencies << "typed_actual_without_selected_source:#{record.id}" unless selected_event_ids.include?(record.financial_source_event_id)
          next
        end
        decision = decisions[record.id]
        if decision&.dig(:disposition) == "exclude"
          deficiencies << "active_actual_excluded:#{record.id}"
          next
        elsif decision&.dig(:disposition) == "match"
          validate_actual_match!(record, decision, records, decisions, source_rows)
          next
        end
        type = decision&.dig(:event_type) || (record.source_type.in?(%w[manual_chat manual_ui receipt screenshot]) ? "purchase" : "unknown")
        deficiencies << "actual_classification_unreviewed:#{record.id}" if type == "unknown"
        deficiencies << "actual_account_unassigned:#{record.id}" unless decision && (decision[:tracked_account_id] || decision[:cash])
        deficiencies << "actual_cash_conflicts_with_declared_scope:#{record.id}" if decision&.dig(:cash) && request[:cash_coverage] == "not_used"
        deficiencies << "actual_account_outside_declared_scope:#{record.id}" if decision&.dig(:tracked_account_id) && !request[:tracked_account_ids].include?(decision[:tracked_account_id])
        splits = record.transaction_splits.map { |split| { budget_category_id: split.budget_category_id, amount_cents: split.amount_cents } }
        if splits.sum { |split| split[:amount_cents] } != record.total_amount_cents
          deficiencies << "actual_split_total_unresolved:#{record.id}"
          splits = [ { budget_category_id: nil, amount_cents: record.total_amount_cents } ]
        end
        expense = type.in?(%w[purchase fee interest])
        { key: "actual:#{record.id}", actual_id: record.id, source_digest: snapshots.find { |row| row[:id] == record.id }[:digest],
          tracked_account_id: decision&.dig(:tracked_account_id), cash: decision&.dig(:cash) == true, classification: type,
          signed_amount_cents: -record.total_amount_cents, purchase_amount_cents: expense ? record.total_amount_cents : nil,
          posted_on: record.occurred_on.iso8601, merchant: record.merchant, expense: expense, source_type: record.source_type,
          overlap_disposition: decision&.dig(:overlap_disposition) || "new", splits: expense ? splits : [] }
      end
      unexpected = decisions.keys - records.map(&:id)
      raise ArgumentError, "Actual decisions must identify active records in the selected window" if unexpected.any?
      [ rows, snapshots ]
    end

    def actual_digest(record)
      HouseholdFinance::Operations::PreparedOperation.fingerprint(transaction: record.attributes.slice("id", "household_id", "financial_source_event_id", "status", "occurred_on", "merchant", "total_amount_cents"),
        splits: record.transaction_splits.sort_by(&:id).map { |split| [ split.id, split.budget_category_id, split.amount_cents ] })
    end

    def validate_actual_match!(record, decision, records, decisions, rows)
      if decision[:source_review_version_id]
        target = rows.find { |row| row[:source_review_version_id] == decision[:source_review_version_id] && row[:expense] }
        valid = target && target[:purchase_amount_cents] == record.total_amount_cents && target[:posted_on] == record.occurred_on.iso8601
      else
        target = records.find { |row| row.id == decision[:matched_transaction_id] }
        target_decision = target && decisions[target.id]
        target_type = target_decision&.dig(:event_type) || (target&.source_type.in?(%w[manual_chat manual_ui receipt screenshot]) ? "purchase" : "unknown")
        valid = target && target.id != record.id && !target.financial_source_event_id && (target_decision.nil? || target_decision[:disposition] == "include") && target_type.in?(%w[purchase fee interest]) && target.total_amount_cents == record.total_amount_cents && target.occurred_on == record.occurred_on
      end
      raise ArgumentError, "An explicit duplicate match needs a current canonical expense with the same complete amount and posted date" unless valid
    end

    def category_rules(rows, refunds)
      rules = request[:category_eligibility].index_by { |row| row[:budget_category_id] }
      ids = (rows.select { |row| row[:expense] }.flat_map { |row| row[:splits].pluck(:budget_category_id) } + refunds.pluck(:budget_category_id)).uniq
      ids.map do |id|
        category = id && household.budget_categories.find(id)
        decision = rules[id]
        deficiencies << "category_eligibility_unreviewed:#{id || 'uncategorized'}" unless decision
        { budget_category_id: id, name: category&.name || "Deliberately uncategorized", stack_key: category&.stack_key,
          active: category&.active?, eligible: decision&.dig(:eligible), recurrence: decision&.dig(:recurrence) || "unknown", reason: decision&.dig(:reason) }
      end.sort_by { |row| row[:budget_category_id].to_i }
    end

    def overlap_warnings(rows)
      actuals = rows.select { |row| row[:actual_id] && row[:expense] && row[:overlap_disposition] != "distinct" }
      actuals.filter_map do |row|
        others = rows.select do |other|
          other[:expense] && other[:key] != row[:key] && other[:source_type] != row[:source_type] &&
            (row[:tracked_account_id].nil? || other[:tracked_account_id].nil? || row[:tracked_account_id] == other[:tracked_account_id]) &&
            other[:posted_on] == row[:posted_on] && other[:purchase_amount_cents] == row[:purchase_amount_cents]
        end
        { actual_id: row[:actual_id], possible_canonical_keys: others.pluck(:key).sort, proof: "date_and_amount_are_not_proof" } if others.any?
      end
    end

    def coverage
      current_identities = SourceAccountIdentityVersion.where(household: household, id: source[:revisions].flat_map { |revision| revision[:state][:account_version_ids] }).includes(:source_tracked_account)
      request[:tracked_account_ids].map do |id|
        intervals = current_identities.select { |identity| identity.source_tracked_account_id == id }.filter_map do |identity|
          revision_id = identity.source_account_review_head.financial_source_account.financial_extraction_revision_id
          status = source[:revisions].find { |revision| revision[:id] == revision_id }
          facts = identity.statement_facts
          if status && status[:participant_approved] && status[:coverage_status] == "complete" && facts["period_start_on"] && facts["period_end_on"]
            [ facts["period_start_on"], facts["period_end_on"] ]
          end
        end.uniq.sort
        reviewed = current_identities.select { |identity| identity.source_tracked_account_id == id }
        period_groups = reviewed.group_by { |identity| identity.statement_facts.values_at("period_start_on", "period_end_on") }
        period_groups.each_value do |identities|
          headers = identities.map { |identity| identity.statement_facts.values_at("opening_balance_cents", "closing_balance_cents", "printed_debit_cents", "printed_credit_cents") }.uniq
          deficiencies << "conflicting_account_period_headers:#{id}" if headers.length > 1
        end
        periods = period_groups.values.map(&:first).sort_by { |identity| identity.statement_facts["period_start_on"].to_s }
        periods.each_cons(2) do |left, right|
          previous, following = left.statement_facts, right.statement_facts
          if previous["period_end_on"] && following["period_start_on"] && Date.iso8601(previous["period_end_on"]) + 1 == Date.iso8601(following["period_start_on"]) && previous["closing_balance_cents"] != following["opening_balance_cents"]
            deficiencies << "account_balance_discontinuity:#{id}"
          end
        end
        missing = missing_ranges(intervals)
        deficiencies << "account_window_incomplete:#{id}" if missing.any?
        { tracked_account_id: id, account_basis: SourceTrackedAccount.current_picture.where(household: household).find(id).account_basis,
          approved_intervals: intervals, missing_ranges: missing, complete: missing.empty? }
      end.tap { deficiencies << "no_declared_statement_accounts" if request[:tracked_account_ids].empty? }
    end

    def validate_known_accounts!
      identities = SourceAccountIdentityVersion.where(household: household).joins(:source_account_review_head)
        .where("source_account_review_heads.approved_version_id = source_account_identity_versions.id")
      known = identities.select do |identity|
        facts = identity.statement_facts
        facts["period_start_on"] && facts["period_end_on"] && facts["period_start_on"] <= end_on.iso8601 && facts["period_end_on"] >= start_on.iso8601
      end.map(&:source_tracked_account_id).uniq
      (known - request[:tracked_account_ids]).each { |id| deficiencies << "known_source_account_omitted:#{id}" }
    end

    def missing_ranges(intervals)
      covered = intervals.flat_map { |first, last| ([ Date.iso8601(first), start_on ].max..[ Date.iso8601(last), end_on ].min).to_a }.to_set
      missing = (start_on..end_on).reject { |day| covered.include?(day) }
      missing.chunk_while { |left, right| right == left + 1 }.map { |chunk| { start_on: chunk.first.iso8601, end_on: chunk.last.iso8601 } }
    end

    def refunds(rows, all_source_rows)
      included = rows.index_by { |row| row[:source_review_version_id] }
      allocations = source[:economic_groups].select { |group| group[:kind] == "refund" }.filter_map do |group|
        purchase = group[:members].find { |member| member[:role] == "original_purchase" }
        refund = group[:members].find { |member| member[:role] == "refund" }
        credit = included[refund[:version_id]]
        next unless credit
        original = all_source_rows.find { |row| row[:source_review_version_id] == purchase[:version_id] }
        original ||= source_row_from_version(purchase[:version_id])
        { economic_group_version_id: group[:id], refund_version_id: refund[:version_id], original_version_id: purchase[:version_id],
          amount_cents: refund[:allocation_cents], posted_on: credit[:posted_on], original_posted_on: original[:posted_on],
          prior_window_purchase: !in_window?(original[:posted_on]), merchant: original[:merchant], budget_category_id: original[:splits].first[:budget_category_id] }
      end
      rows.select { |row| row[:classification] == "refund" }.each do |row|
        unallocated = row[:signed_amount_cents] - allocations.select { |entry| entry[:refund_version_id] == row[:source_review_version_id] }.sum { |entry| entry[:amount_cents] }
        deficiencies << "refund_allocation_unresolved:#{row[:source_review_version_id]}" if unallocated.positive?
      end
      allocations.sort_by { |row| [ row[:posted_on], row[:economic_group_version_id] ] }
    end

    def source_row_from_version(id)
      version = SourceReviewVersion.where(household: household).find(id)
      raise ArgumentError, "A refund's original reviewed source fact is stale" unless version.source_review_head.approved_version_id == version.id && version.expense?
      { posted_on: version.posted_on.iso8601, merchant: version.merchant, splits: [ { budget_category_id: version.budget_category_id } ] }
    end

    def cash_summary(rows)
      withdrawals = rows.select { |row| row[:classification] == "cash_withdrawal" && row[:signed_amount_cents].negative? }
      by_version = withdrawals.index_by { |row| row[:source_review_version_id] }
      actuals = rows.select { |row| row[:actual_id] && row[:expense] && row[:cash] }.index_by { |row| row[:actual_id] }
      request[:cash_allocations].each do |allocation|
        raise ArgumentError, "Cash allocation needs a selected approved withdrawal and included cash purchase" unless by_version[allocation[:source_review_version_id]] && actuals[allocation[:transaction_id]]
      end
      by_version.each do |id, row|
        raise ArgumentError, "Cash allocations exceed the withdrawal" if request[:cash_allocations].select { |allocation| allocation[:source_review_version_id] == id }.sum { |allocation| allocation[:amount_cents] } > row[:signed_amount_cents].abs
      end
      actuals.each do |id, row|
        raise ArgumentError, "Cash allocations exceed the purchase" if request[:cash_allocations].select { |allocation| allocation[:transaction_id] == id }.sum { |allocation| allocation[:amount_cents] } > row[:purchase_amount_cents]
      end
      total = withdrawals.sum { |row| row[:signed_amount_cents].abs }
      allocated = request[:cash_allocations].sum { |allocation| allocation[:amount_cents] }
      { withdrawal_cents: total, allocated_purchase_cents: allocated, unallocated_withdrawal_cents: total - allocated,
        manual_cash_purchase_cents: actuals.values.sum { |row| row[:purchase_amount_cents] }, coverage: request[:cash_coverage],
        cash_balance_known: false, savings_inferred: false }
    end

    def in_window?(date)
      date && date.between?(start_on.iso8601, end_on.iso8601)
    end

    def full_month_count
      cursor = start_on.beginning_of_month
      count = 0
      while cursor <= end_on
        count += 1 if cursor >= start_on && cursor.end_of_month <= end_on
        cursor = cursor.next_month
      end
      count
    end
  end
end
