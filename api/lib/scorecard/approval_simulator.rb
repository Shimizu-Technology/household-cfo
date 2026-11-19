module Scorecard
  class ApprovalSimulator
    REVIEW = FinancialDocuments::SourceReview
    attr_reader :decisions, :row_answers, :transaction_answers, :receipt_observations, :quality

    def initialize(household:, user:, answer_key:, categories:, correct_proposals: true)
      @household, @key, @categories = household, answer_key, categories
      @correct_proposals = correct_proposals
      @quality = Hash.new { |hash, month| hash[month] = { "manual_correction" => 0, "manual_exclusion" => 0, "accepted_as_proposed" => 0, "corrections_by_field" => %w[type amount date category direction].index_with(0), "questions_by_kind" => Hash.new(0) } }
      @domain = REVIEW::Domain.new(household, user: user)
      @decisions = Hash.new { |hash, month| hash[month] = Hash.new(0) }
      @row_answers = {}
      @transaction_answers = {}
      @receipt_observations = {}
      @included_legs = Set.new
      @same_charge_ids = Set.new
    end

    def call(document, doc)
      @document = doc
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
          month = answer ? @key.event(answer).fetch("date")[0, 7] : doc.fetch("period").fetch("start_on")[0, 7]
          quality[month]["questions_by_kind"][line.kind.to_s] += 1 if line.kind
          entry = answer_for(line, answer, month)
          # One submitted line answer is one action, even when that answer also
          # corrects fields or excludes a row. Quality counters are separate.
          action = line.kind || (entry[:decision] == "leave_out" ? :manual_exclusion : entry[:decision] == "edited" ? :manual_correction : nil)
          count(doc, action, answer) if action
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
      # Reuse the displayed page plan when retrying its answers individually.
      # Rebuilding a 298-row CSV plan for each answer obscures CI runtime with
      # harness work. apply! is the same production validation/stage/approve
      # path called by LineApprover#call; every failed save still rolls back.
      plan = REVIEW::ParticipantPlan.new(@household, revision)
      form = REVIEW::LineApprover.new(@domain, revision, {})
      @domain.overlap_context = REVIEW::OverlapDetector::Context.new(@household)
      begin
        input[:lines].each do |entry|
          begin
            @household.with_lock { form.send(:apply!, plan, entry, Hash.new(0)) }
          rescue ArgumentError => line_error
            raise unless line_error.message.include?("rows may overlap")
            answer = row_answers.fetch(entry.fetch(:event_id))
            count_for(answer, :duplicate_guard)
            if !@correct_proposals && answer && @same_charge_ids.include?(entry.fetch(:event_id))
              excluded = entry.merge(decision: "leave_out").except(:edit)
              @household.with_lock { form.send(:apply!, plan, excluded, Hash.new(0)) }
            else
              approve_distinct(revision, entry, line: plan.line_for(entry.fetch(:event_id)))
            end
          end
          @domain.overlap_context.refresh!
        end
      ensure
        @domain.overlap_context = nil
      end
    end

    def approve_distinct(revision, entry, line:)
      event = revision.financial_source_events.find(entry.fetch(:event_id))
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

    def answer_for(line, answer, month)
      row = line.event
      base = { event_id: row.id, shown: { event_type: row.event_type, category_id: line.category_id }, expected_head: line.expected_head }
      unless answer
        # An unmapped proposal must remain visible in the question-only output
        # when the app accepts it; the answer key cannot silently remove it.
        if !@correct_proposals && !line.kind.in?(%i[unclear direction no_category duplicate])
          return base.merge(decision: "as_read")
        end
        quality[month]["manual_exclusion"] += 1 if @correct_proposals
        return base.merge(decision: "leave_out")
      end
      return base.merge(decision: "as_read") if row.row_kind == "informational"
      expected = @key.event(answer)
      excluded = @included_legs.include?(leg_key(answer)) || answer["status"] == "pending"
      @same_charge_ids << row.id if excluded
      if excluded && (@correct_proposals || line.kind.in?(%i[duplicate unclear]))
        quality[month]["manual_exclusion"] += 1 unless line.kind == :duplicate || (line.kind == :unclear && answer["status"] == "pending")
        return base.merge(decision: "leave_out")
      end
      return base.merge(decision: "leave_out") if !@correct_proposals && line.kind == :unclear
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
      proposed_amount = row.signed_amount_cents&.abs || HouseholdFinance::Money.document_cents(row.financial_source_evidence&.payload&.fetch("source_amount_text", nil), negative_as_magnitude: true)
      fields = []
      fields << "type" if row.event_type != expected_type
      fields << "amount" if proposed_amount != signed.abs
      fields << "direction" if row.signed_amount_cents.nil? || row.signed_amount_cents.positive? != signed.positive?
      fields << "date" if row.posted_on&.iso8601 != answer.fetch("date")
      fields << "category" if kind == "spending" && line.category_id != category
      quality[month]["accepted_as_proposed"] += 1 if fields.empty? && !excluded
      allowed = case line.kind
      when :direction then %w[type direction category]
      when :transfer, :card_payment, :refund then %w[type direction category]
      when :no_category, :suggested_category, :still_category then %w[category]
      else []
      end
      changes = @correct_proposals ? fields : fields & allowed
      if changes.any?
        quality[month]["manual_correction"] += 1
        changes.each { |field| quality[month]["corrections_by_field"][field] += 1 }
      end
      return base.merge(decision: line.kind == :duplicate ? "different" : "as_read") if changes.empty? && !line.kind.in?(%i[direction unclear no_category])
      proposed_kind = { "income" => "money_in", "transfer" => "moved", "debt_payment" => "card", "cash_withdrawal" => "cash", "refund" => "refund" }[row.event_type] || "spending"
      edit = { kind: changes.include?("type") || line.kind == :direction ? kind : proposed_kind,
        category_id: changes.include?("category") ? category : line.category_id,
        amount_cents: changes.include?("amount") ? signed.abs : proposed_amount,
        money_direction: changes.include?("direction") ? (signed.positive? ? "in" : "out") : (row.signed_amount_cents.to_i.positive? ? "in" : "out"),
        posted_on: changes.include?("date") ? answer.fetch("date") : row.posted_on&.iso8601 }
      base.merge(decision: "edited", edit: edit)
    end

    def count_for(answer, kind)
      return count(@document, kind) unless answer
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
        matches = HouseholdFinance::TransactionDraftMatcher.new(draft).call
        event_id = doc.fetch("receipt").fetch("matching_bank_event_id")
        match = matches.find { |candidate| row_answers[candidate.household_transaction.financial_source_event_id]&.fetch("event_id") == event_id }
        if match
          count(doc, :receipt_match)
          result = HouseholdFinance::TransactionDraftMatchAccepter.new(draft, match_id: match.id).call
          raise "Receipt match failed" unless result.success?
          receipt_observations.fetch(doc.fetch("path"))["matched"] = true
        else
          expected = doc.fetch("receipt")
          answer = doc.fetch("lines").first
          month = @key.event(answer).fetch("date")[0, 7]
          allocations = expected.fetch("expected_category_allocations")
          fields = []
          fields << "amount" if draft.total_amount_cents != expected.fetch("new_money_cents")
          fields << "date" if draft.occurred_on&.iso8601 != answer.fetch("date")
          actual = draft.transaction_draft_splits.ordered.map { |split| [ split.budget_category&.name || split.category_name, split.amount_cents ] }.sort
          wanted = allocations.map { |allocation| [ allocation.fetch("category"), allocation.fetch("spending_cents") ] }.sort
          fields << "category" unless actual == wanted
          quality[month]["accepted_as_proposed"] += 1 if fields.empty?
          attributes = {}
          if @correct_proposals && fields.any?
            quality[month]["manual_correction"] += 1
            fields.each { |field| quality[month]["corrections_by_field"][field] += 1 }
            attributes = { amount: HouseholdFinance::Money.dollars(expected.fetch("new_money_cents")), occurred_on: answer.fetch("date"),
              splits: allocations.map { |allocation| { budget_category_id: @categories.fetch(allocation.fetch("category")).id, amount: HouseholdFinance::Money.dollars(allocation.fetch("spending_cents")) } } }
          elsif draft.transaction_draft_splits.any? { |split| split.budget_category_id.nil? }
            # The receipt cannot be confirmed without answering its category question.
            attributes[:splits] = draft.transaction_draft_splits.ordered.map do |split|
              category = @categories[split.category_name] || @categories[@key.event(answer)["category"]]
              { id: split.id, budget_category_id: category&.id, amount: HouseholdFinance::Money.dollars(split.amount_cents) }
            end
          end
          result = HouseholdFinance::TransactionDraftConfirmer.new(draft, attributes).call
          if result.possible_matches.present?
            # The app asks "Same purchase as …?" before it can count twice. Both
            # views answer from the answer key, like any other duplicate question.
            same = result.possible_matches.find { |candidate| bank_event_id(candidate.fetch(:transaction_id)) == event_id }
            if same
              accept_asked_receipt_match!(draft, attributes, same.fetch(:transaction_id), doc)
              next
            end
            result = HouseholdFinance::TransactionDraftConfirmer.new(draft, attributes, different_purchase: true).call
          end
          count(doc, :receipt_confirmation)
          raise "Receipt confirmation failed: #{result.errors.join(', ')}" unless result.success?
          transaction_answers[result.transaction.id] = doc.fetch("lines").first
        end
      end
    end

    def bank_event_id(transaction_id)
      row_answers[HouseholdTransaction.find(transaction_id).financial_source_event_id]&.fetch("event_id")
    end

    # "Same purchase": the receipt form saves her corrections, the card shows
    # the bank line it matches, and she matches it. One receipt-match action.
    def accept_asked_receipt_match!(draft, attributes, transaction_id, doc)
      if attributes.any?
        saved = HouseholdFinance::TransactionDraftUpdater.new(draft, attributes).call
        raise "Receipt correction failed: #{saved.errors.join(', ')}" unless saved.success?
      else
        HouseholdFinance::TransactionDraftMatcher.new(draft).call
      end
      match = draft.transaction_draft_matches.proposed.find_by!(household_transaction_id: transaction_id)
      count(doc, :receipt_match)
      result = HouseholdFinance::TransactionDraftMatchAccepter.new(draft, match_id: match.id).call
      raise "Receipt match failed" unless result.success?
      receipt_observations.fetch(doc.fetch("path"))["matched"] = true
    end

    def count(doc, kind, answer = nil)
      month = answer ? @key.event(answer).fetch("date")[0, 7] : doc.fetch("period").fetch("start_on")[0, 7]
      decisions[month][kind.to_s] += 1
    end
  end
end
