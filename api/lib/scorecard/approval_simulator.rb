module Scorecard
  class ApprovalSimulator
    REVIEW = FinancialDocuments::SourceReview
    attr_reader :decisions, :row_answers, :transaction_answers, :receipt_observations

    def initialize(household:, user:, answer_key:, categories:)
      @household, @key, @categories = household, answer_key, categories
      @domain = REVIEW::Domain.new(household, user: user)
      @decisions = Hash.new { |hash, month| hash[month] = Hash.new(0) }
      @row_answers = {}
      @transaction_answers = {}
      @receipt_observations = {}
      @included_legs = Set.new
    end

    def call(document, doc)
      revision = document.financial_extraction_revisions.order(:id).last
      rows = revision.financial_source_events.includes(:financial_source_evidence).order(:position, :id).to_a
      mappings = @key.map_rows(doc, rows)
      @row_answers.merge!(mappings)
      if doc["receipt"]
        @receipt_observations[doc.fetch("path")] = {
          "extracted_new_money_cents" => rows.sum { |row| row.expense_amount_cents.to_i } + document.transaction_drafts.where(financial_source_event_id: nil).sum(:total_amount_cents),
          "matched" => false
        }
      end
      if revision.contract_version != FinancialDocuments::AccountingContract::VERSION
        review_receipts(document, doc) if doc["receipt"]
        return
      end
      accounts = revision.financial_source_accounts.order(:id).map do |account|
        identity = @key.identity_for(doc, account, mappings)
        count(doc, :account_identity)
        { source_account_id: account.id, account_basis: identity.fetch("account_basis"),
          label: "#{identity.fetch('institution')} #{identity.fetch('masked_identifier')}" }
      end
      approve(revision, lines: [], accounts: accounts) if accounts.any?
      # A page is reviewed as displayed; answers on that page do not magically
      # teach the earlier questions on the same page a new category.
      rows.each_slice(50) do |page|
        plan = REVIEW::ParticipantPlan.new(@household, revision)
        count(doc, :approve_page)
        entries = page.map do |row|
          line = plan.line_for(row.id)
          answer = mappings[row.id]
          count(doc, line.kind, answer) if line.kind
          entry = answer_for(line, answer)
          @included_legs << leg_key(answer) if answer && entry[:decision] != "leave_out" && row.row_kind != "informational"
          entry
        end
        if doc["receipt"]
          entries.each do |entry|
            answer = mappings[entry.fetch(:event_id)]
            if answer && entry[:decision] == "leave_out" && answer["status"] != "pending"
              match_receipt(revision, entry, answer, doc)
            else
              approve(revision, lines: [ entry ])
            end
          end
        else
          approve(revision, lines: entries) if entries.any?
        end
      end
      state = REVIEW::ApprovalState.new(@household, revision).call
      if REVIEW::CoverageQuestion.text(revision, deficiencies: state[:deficiencies])
        count(doc, :coverage)
        covered = mappings.values.compact.map { |line| line["line_id"] }.uniq.length == doc.fetch("lines").length
        approve(revision, lines: [], coverage_answer: covered ? "nothing_missing" : "something_missing",
          expected_coverage_id: REVIEW::CoverageQuestion.latest(revision)&.id)
      end
      review_receipts(document, doc) if doc["kind"] == "receipt"
    end

    private

    def approve(revision, input)
      @household.with_lock { REVIEW::LineApprover.new(@domain, revision, input).call }
    rescue ArgumentError => error
      raise unless error.message.include?("rows may overlap") && input[:lines].present?
      input[:lines].each do |entry|
        begin
          @household.with_lock { REVIEW::LineApprover.new(@domain, revision, { lines: [ entry ] }).call }
        rescue ArgumentError => line_error
          raise unless line_error.message.include?("rows may overlap")
          # The stage/approve guard can reveal an overlap after a direction edit,
          # or for identical rows on the same statement. Answer that extra
          # question through the production source proposal review operation.
          answer = row_answers.fetch(entry.fetch(:event_id))
          count_for(answer, :duplicate_guard)
          approve_distinct(revision, entry)
        end
      end
    end

    def approve_distinct(revision, entry)
      event = revision.financial_source_events.find(entry.fetch(:event_id))
      line = REVIEW::ParticipantPlan.new(@household, revision).line_for(event.id)
      identity = @domain.account_heads.find_by!(financial_source_account_id: event.financial_source_account_id).approved_version
      # Use the same participant edit interpretation and projection as the line
      # form, then explicitly answer the additional overlap guard.
      form = REVIEW::LineApprover.new(@domain, revision, {})
      facts = form.send(:facts_for, line, entry.fetch(:decision), entry.fetch(:edit, {}), identity.id).merge(overlap_disposition: "distinct")
      head = @domain.heads.find_by(financial_source_event_id: event.id)
      input = { event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0,
        expected_pending_draft: nil, facts: facts, projection: form.send(:projection_for, event, facts), reason: "Participant confirmed distinct activity in scorecard review." }
      draft = @domain.execute("stage", @domain.normalize("stage", input))
      @domain.execute("approve", @domain.normalize("approve", draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest))
    end

    def leg_key(answer)
      # The group has two legitimate purchases. Preserve cardinality while
      # letting either indistinguishable twin match either later copy.
      answer["match_key"] || answer.fetch("leg_id")
    end

    def answer_for(line, answer)
      row = line.event
      base = { event_id: row.id, shown: { event_type: row.event_type, category_id: line.category_id }, expected_head: line.expected_head }
      return base.merge(decision: "leave_out") unless answer
      return base.merge(decision: "as_read") if row.row_kind == "informational"
      expected = @key.event(answer)
      if @included_legs.include?(leg_key(answer)) || answer["status"] == "pending"
        count_for(answer, :manual_exclusion) unless line.kind == :duplicate
        return base.merge(decision: "leave_out")
      end
      type = expected.fetch("event_kind")
      kind = case type
      when "income" then "money_in"
      when "transfer_own_accounts" then "moved"
      when "card_payment" then "card"
      when "cash_withdrawal" then "cash"
      when "refund" then "refund"
      else "spending"
      end
      category = @categories[expected["category"]]&.id
      signed = answer.fetch("signed_amount_cents")
      expected_type = { "money_in" => "income", "moved" => "transfer", "card" => "debt_payment", "cash" => "cash_withdrawal", "refund" => "refund" }[kind] || (type.in?(%w[fee interest]) ? type : "purchase")
      wrong = row.event_type != expected_type || row.signed_amount_cents != signed || row.posted_on&.iso8601 != answer.fetch("date") ||
        (kind == "spending" && line.category_id != category)
      return base.merge(decision: line.kind == :duplicate ? "different" : "as_read") unless wrong || line.kind.in?(%i[direction unclear no_category])
      count_for(answer, :manual_correction) unless line.kind
      edit = { kind: kind, category_id: category, amount_cents: signed.abs,
        money_direction: signed.positive? ? "in" : "out", posted_on: answer.fetch("date") }
      base.merge(decision: "edited", edit: edit)
    end

    def count_for(answer, kind)
      decisions[@key.event(answer).fetch("date")[0, 7]][kind.to_s] += 1
    end

    def match_receipt(revision, entry, answer, doc)
      target_event_ids = row_answers.select { |id, other| id != entry.fetch(:event_id) && other && other["leg_id"] == answer["leg_id"] }.keys
      target = SourceReviewVersion.where(id: SourceReviewHead.where(financial_source_event_id: target_event_ids).select(:approved_version_id), disposition: "include").order(:id).first
      return approve(revision, lines: [ entry ]) unless target
      count(doc, :receipt_match)
      event = revision.financial_source_events.find(entry.fetch(:event_id))
      identity = @domain.account_heads.find_by!(financial_source_account_id: event.financial_source_account_id).approved_version
      facts = target.reviewed_facts.symbolize_keys.except(:matched_version_id).merge(source_account_identity_version_id: identity.id,
        disposition: "match", overlap_disposition: "match", matched_version_id: target.id)
      input = { event_id: event.id, base_version_id: nil, base_lock_version: 0, expected_pending_draft: nil,
        facts: facts, projection: { action: "none" }, reason: "Participant matched receipt to its bank activity." }
      draft = @domain.execute("stage", @domain.normalize("stage", input))
      @domain.execute("approve", @domain.normalize("approve", draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest))
      receipt_observations.fetch(doc.fetch("path"))["matched"] = true
    end

    def review_receipts(document, doc)
      # Legacy receipt reviews use transaction drafts, not source-line review.
      document.transaction_drafts.where(financial_source_event_id: nil, status: "pending").each do |draft|
        count(doc, :receipt_confirmation)
        matches = HouseholdFinance::TransactionDraftMatcher.new(draft).call
        event_id = doc.fetch("receipt").fetch("matching_bank_event_id")
        match = matches.find { |candidate| row_answers[candidate.household_transaction.financial_source_event_id]&.fetch("event_id") == event_id }
        if match
          count(doc, :receipt_match)
          result = HouseholdFinance::TransactionDraftMatchAccepter.new(draft, match_id: match.id).call
          raise "Receipt match failed" unless result.success?
          receipt_observations.fetch(doc.fetch("path"))["matched"] = true
        else
          # A careful user may choose categories, but the app must supply the
          # receipt's tender amount and splits. A missing match stays visible.
          splits = draft.transaction_draft_splits.ordered.map do |split|
            category = @categories[split.category_name] || @categories[@key.event(doc.fetch("lines").first)["category"]]
            count(doc, :receipt_category) unless split.budget_category_id == category&.id
            { id: split.id, budget_category_id: category&.id, amount: HouseholdFinance::Money.dollars(split.amount_cents) }
          end
          result = HouseholdFinance::TransactionDraftConfirmer.new(draft, { splits: splits }).call
          raise "Receipt confirmation failed: #{result.errors.join(', ')}" unless result.success?
          transaction_answers[result.transaction.id] = doc.fetch("lines").first
        end
      end
    end

    def count(doc, kind, answer = nil)
      month = answer ? @key.event(answer).fetch("date")[0, 7] : doc.fetch("period").fetch("start_on")[0, 7]
      decisions[month][kind.to_s] += 1
    end
  end
end
