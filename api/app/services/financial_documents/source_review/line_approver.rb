module FinancialDocuments
  module SourceReview
    # Saves a participant's answers for many statement lines in one step, all or none.
    # It only chains the same account, stage, approve and coverage steps a single
    # line goes through, under the caller's household lock and transaction, so every
    # existing guard still applies and any failure rolls the whole request back.
    # Facts come from the statement as read plus the participant's explicit answer;
    # the client never supplies amounts for lines it did not edit.
    class LineApprover
      REASON = "Approved from the statement review.".freeze
      TOOLS = %w[source_review.account.link source_review.draft.stage source_review.draft.approve source_review.revision.approve].freeze
      DECISIONS = %w[as_read different leave_out edited].freeze
      KINDS = { "spending" => "purchase", "money_in" => "income", "moved" => "transfer", "card" => "debt_payment", "cash" => "cash_withdrawal", "refund" => "refund" }.freeze
      MAX_LINES = 100
      NOT_REVIEWED = %w[unreviewed_source_rows unreviewed_source_accounts account_identity_changed].freeze

      def initialize(domain, revision, input, cohort_membership: nil)
        @domain, @revision, @input, @cohort_membership = domain, revision, input, cohort_membership
      end

      def call
        TOOLS.each { |key| CohortReleases::OperationAccess.require!(household: household, user: domain.user, key: key, membership: @cohort_membership) }
        entries = Array(input[:lines]).map { |entry| entry.to_h.deep_symbolize_keys }
        answer = input[:coverage_answer].presence
        raise ArgumentError, "Choose whether anything is missing from this statement" if answer && !answer.in?(CoverageQuestion::ANSWERS)
        raise ArgumentError, "Choose at least one line to approve" if entries.empty? && input[:accounts].blank? && answer.nil?
        raise ArgumentError, "Approve up to #{MAX_LINES} lines at a time." if entries.length > MAX_LINES
        link_accounts!
        plan = ParticipantPlan.new(household, revision)
        check_expected!(plan, entries)
        counts = Hash.new(0)
        entries.sort_by { |entry| plan.line_for(entry.fetch(:event_id).to_i)&.event&.position.to_i }.each { |entry| apply!(plan, entry, counts) }
        { approved: counts[:approved], left_out: counts[:left_out], unchanged: counts[:unchanged], complete: finish_coverage!(answer) }
      rescue KeyError, TypeError
        raise ArgumentError, "Statement review request is missing required fields"
      end

      private

      attr_reader :domain, :revision, :input

      def household = domain.household

      # "Approve the rest" must cover exactly the lines that were on screen as looking right.
      # A long statement is approved a page at a time (paged: true): every line on the page must still look right,
      # and only those lines are saved. A page that already saved is a no-op, so a retry changes nothing.
      def check_expected!(plan, entries)
        return unless input.key?(:expect_ready_ids)
        expected = Array(input[:expect_ready_ids]).map(&:to_i).uniq.sort
        ready = plan.lines.select(&:ready?)
        open = ready.reject(&:done).map { |line| line.event.id }.sort
        covered = (expected - ready.map { |line| line.event.id }).empty? && (input[:paged] == true || (open - expected).empty?)
        unless covered
          raise Domain::StaleReview, "This statement changed while you were reviewing it. Nothing was saved. Refresh and try again."
        end
        entries.each { |entry| check_shown!(plan.line_for(entry.fetch(:event_id).to_i), entry, required: true) if entry[:decision].to_s == "as_read" }
      end

      # What is saved must be exactly what she was shown: the line's kind and category as they were on her screen.
      # A request that does not say what she saw, or saw something else, saves nothing.
      def check_shown!(line, entry, required:)
        raise ArgumentError, "Statement review request is missing required fields" if line.nil? || (required && !entry[:shown].is_a?(Hash))
        return unless entry[:shown].is_a?(Hash)
        shown = entry[:shown]
        raise ArgumentError, "Statement review request is missing required fields" unless shown.key?(:category_id) && shown.key?(:event_type)
        return if shown[:event_type].to_s == line.event.event_type && shown[:category_id]&.to_i == line.category_id
        raise Domain::StaleReview, "This line changed while you were looking at it. Nothing was saved. Please look again."
      end

      def link_accounts!
        revision.financial_source_accounts.order(:id).each do |account|
          head = domain.account_heads.find_by(financial_source_account_id: account.id)
          change = Array(input[:accounts]).map { |row| row.to_h.deep_symbolize_keys }.find { |row| row[:source_account_id].to_i == account.id } || {}
          current = head&.approved_version
          next if current && change.empty?
          tracked = current&.source_tracked_account
          basis = change[:account_basis].presence || tracked&.account_basis || (account.account_basis unless account.account_basis == "unknown")
          raise ArgumentError, "Choose whether this is a bank account or a credit card." unless basis.in?(%w[asset liability])
          label = change[:label].presence || tracked&.label || account_label(account, basis)
          facts = statement_facts(account, current, change)
          # A repeat of a change that already saved must not append another identity: that would make every line approved under it stale.
          next if current && tracked.label == label && tracked.account_basis == basis && current.statement_facts.symbolize_keys.slice(:period_start_on, :period_end_on) == facts.slice(:period_start_on, :period_end_on)
          # A generic fallback name ("Bank account") says nothing about which account it is: two unnamed accounts must stay two,
          # or a charge in one would be offered as a duplicate of the same charge in the other.
          named = change[:label].present? || tracked.present? || label.include?("····")
          existing = named ? SourceTrackedAccount.current_picture.where(household: household, label: label, account_basis: basis).order(:id).first : nil
          raw = { source_account_id: account.id, tracked_account_id: existing&.id, label: label, account_basis: basis,
            base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0, statement_facts: facts, reason: REASON }
          domain.execute("account_link", domain.normalize("account_link", raw))
        end
      end

      def account_label(account, basis)
        payload = account.financial_source_evidence&.payload || {}
        AccountName.default_label(payload["label"], payload["masked_identifier"], basis)
      end

      def statement_facts(account, current, change)
        facts = current ? current.statement_facts.symbolize_keys : {
          period_start_on: account.period_start_on&.iso8601, period_end_on: account.period_end_on&.iso8601,
          opening_balance_cents: account.opening_balance_cents, closing_balance_cents: account.closing_balance_cents,
          printed_debit_cents: account.printed_debit_cents, printed_credit_cents: account.printed_credit_cents,
          printed_row_count: account.printed_row_count, printed_row_count_basis: "posted"
        }
        facts[:period_start_on] = change[:period_start_on].presence || facts[:period_start_on]
        facts[:period_end_on] = change[:period_end_on].presence || facts[:period_end_on]
        facts
      end

      def apply!(plan, entry, counts)
        line = plan.line_for(entry.fetch(:event_id).to_i) || raise(ActiveRecord::RecordNotFound)
        decision = entry.fetch(:decision).to_s
        raise ArgumentError, "Unknown answer for a statement line" unless decision.in?(DECISIONS)
        event = line.event
        identity = domain.account_heads.find_by(financial_source_account_id: event.financial_source_account_id)&.approved_version
        facts = facts_for(line, decision, entry[:edit].to_h.deep_symbolize_keys, identity.id)
        head = domain.heads.find_by(financial_source_event_id: event.id)
        if line.done && same_facts?(head.approved_version, facts)
          counts[:unchanged] += 1
          return
        end
        check_allowed!(line, decision, entry)
        stage_and_approve!(event, head, facts)
        counts[decision == "leave_out" ? :left_out : :approved] += 1
      end

      def check_allowed!(line, decision, entry)
        stale = Domain::StaleReview.new("This line changed while you were reviewing it. Nothing was saved. Refresh and try again.")
        case decision
        when "as_read"
          raise stale unless !line.done && (line.ready? || line.kind.in?(%i[transfer card_payment refund still_category]))
          # "Yes" to "Still Dining out?" confirms the category she was asked about and nothing else: the line keeps its kind.
          check_shown!(line, entry, required: true) if line.kind == :still_category
        when "different"
          raise stale unless line.kind == :duplicate
          raise ArgumentError, "That line is already in your numbers, so it can only be left out." if line.overlaps.any? { |row| row[:strength] == "strong" && row[:approved_version_id] }
        end
      end

      def facts_for(line, decision, edit, identity_id)
        base = ParticipantPlan.facts_as_read(line.event, identity_id: identity_id, merchant: line.merchant, category_id: line.category_id)
        case decision
        when "as_read" then base
        when "different" then base.merge(overlap_disposition: "distinct")
        when "leave_out" then base.merge(disposition: "exclude", purchase_amount_cents: nil, budget_category_id: nil, overlap_disposition: "excluded")
        else edited_facts(base, line.event, edit)
        end
      end

      def edited_facts(base, event, edit)
        kind = edit[:kind].to_s
        type = KINDS.fetch(kind) { raise ArgumentError, "Choose what this line was" }
        # "Spending" covers fees and interest too: choosing a category for one must not turn it into a purchase.
        type = event.event_type if kind == "spending" && event.event_type.in?(ParticipantPlan::EXPENSE_TYPES)
        cents = edit.key?(:amount_cents) ? edit[:amount_cents] : event.signed_amount_cents&.abs
        raise ArgumentError, "Enter the amount for this line" unless cents.is_a?(Integer) && cents.positive?
        signed = case kind
        when "spending", "cash" then -cents
        when "moved", "card" then (event.signed_amount_cents.to_i.positive? ? cents : -cents)
        else cents
        end
        merchant = edit[:merchant].to_s.squish.presence || base[:merchant]
        base.merge(disposition: "include", event_type: type, signed_amount_cents: signed, posted_on: edit[:posted_on].presence || base[:posted_on], merchant: merchant,
          purchase_amount_cents: kind == "spending" ? cents : nil, budget_category_id: kind == "spending" ? edit[:category_id].presence&.to_i : nil, overlap_disposition: "new")
      end

      def same_facts?(version, facts)
        return false unless version
        version.reviewed_facts.slice(*%i[disposition event_type signed_amount_cents purchase_amount_cents posted_on merchant budget_category_id overlap_disposition]).stringify_keys ==
          facts.slice(*%i[disposition event_type signed_amount_cents purchase_amount_cents posted_on merchant budget_category_id overlap_disposition]).stringify_keys
      end

      def stage_and_approve!(event, head, facts)
        pending = head&.source_review_drafts&.pending&.first
        raw = { event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0,
          expected_pending_draft: pending && { id: pending.id, lock_version: pending.lock_version, digest: pending.digest },
          facts: facts, projection: projection_for(event, facts), reason: REASON }
        draft = domain.execute("stage", domain.normalize("stage", raw)).reload
        domain.execute("approve", domain.normalize("approve", draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest))
      end

      # Counts as spending only when the participant approved a categorized purchase outflow.
      def projection_for(event, facts)
        actuals = household.household_transactions.where(financial_source_event: event, status: %w[confirmed reconciled]).order(:id).limit(2).to_a
        actual = actuals.one? ? actuals.first : nil
        category = facts[:budget_category_id] && household.budget_categories.find_by(id: facts[:budget_category_id])
        spending = facts[:disposition] == "include" && facts[:event_type].in?(ParticipantPlan::EXPENSE_TYPES) && facts[:signed_amount_cents].to_i.negative? &&
          category&.active && facts[:purchase_amount_cents] == facts[:signed_amount_cents].abs && facts[:posted_on] &&
          HouseholdFinance::AnnualBudgetManager.supported_year?(Date.iso8601(facts[:posted_on]).year)
        return { action: spending ? "create" : "none" } unless actual
        { action: spending ? "replace" : "void", transaction_id: actual.id, expected_digest: ProjectionCorrector.snapshot_digest(actual) }
      end

      # The statement is only marked finished once every line and account has an approved decision.
      #
      # Whether every row of the document is accounted for is her statement to make, never the system's. A statement that
      # proves its own coverage (its printed totals match) needs no question; otherwise there is no coverage approval until
      # she answers, and "something's missing" is recorded as not attested.
      def finish_coverage!(answer)
        state = ApprovalState.new(household, revision).call
        return false if (state[:deficiencies] & NOT_REVIEWED).any? || state[:pending_corrections].positive?
        asked = CoverageQuestion.text(revision, deficiencies: state[:deficiencies]).present?
        said = answer || CoverageQuestion.answer(revision)
        return false if asked && said.nil?
        accounted = !asked || said == "nothing_missing"
        last = SourceRevisionApproval.where(household: household, financial_extraction_revision: revision).order(version_number: :desc).first
        return true if last&.digest == state[:content_digest] && last.coverage_attestation["all_document_rows_accounted"] == accounted
        accounts = revision.financial_source_accounts.order(:id).map do |account|
          identity = domain.account_heads.find_by(financial_source_account_id: account.id).approved_version
          { source_account_id: account.id, identity_version_id: identity.id, period_start_on: identity.statement_facts["period_start_on"],
            period_end_on: identity.statement_facts["period_end_on"], all_rows_accounted: accounted }
        end
        raw = { revision_id: revision.id, requested_status: state[:deficiencies].empty? ? "complete" : "qualified", expected_digest: state[:content_digest],
          reason: REASON, coverage_attestation: { all_document_rows_accounted: accounted, accounts: accounts } }
        domain.execute("revision_approve", domain.normalize("revision_approve", raw))
        true
      end
    end
  end
end
