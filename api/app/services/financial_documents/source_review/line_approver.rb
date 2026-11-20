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
      TOOLS = %w[source_review.account.link source_review.draft.stage source_review.draft.approve source_review.revision.approve source_review.economic.link].freeze
      DECISIONS = %w[as_read different same_purchase leave_out edited own_account someone_else pair_transfer unpair_transfer].freeze
      KINDS = { "spending" => "purchase", "money_in" => "income", "moved" => "transfer", "card" => "debt_payment", "cash" => "cash_withdrawal", "refund" => "refund" }.freeze
      MAX_LINES = 100
      NOT_REVIEWED = %w[unreviewed_source_rows unreviewed_source_accounts account_identity_changed].freeze

      def initialize(domain, revision, input, cohort_membership: nil)
        @domain, @revision, @input, @cohort_membership = domain, revision, input, cohort_membership
      end

      def call
        HouseholdFinance::FinancialGenerationGuard.request!(household)
        FinancialPicture.set(household_id: household.id, generation: household.financial_generation) { perform }
      end

      def perform
        CohortReleases::OperationAccess.require_all!(household: household, user: domain.user, keys: TOOLS, membership: @cohort_membership)
        entries = Array(input[:lines]).map { |entry| entry.to_h.deep_symbolize_keys }
        raise ArgumentError, "Choose each statement line only once" unless entries.map { |entry| entry.fetch(:event_id).to_i }.uniq.length == entries.length
        answer = input[:coverage_answer].presence
        raise ArgumentError, "Choose whether anything is missing from this statement" if answer && !answer.in?(CoverageQuestion::ANSWERS)
        if answer && input[:expected_coverage_id] != CoverageQuestion.latest(revision)&.id
          raise Domain::StaleReview, "The coverage answer was changed in another window. Nothing was saved. Refresh to review the latest answer."
        end
        raise ArgumentError, "Choose at least one line to approve" if entries.empty? && input[:accounts].blank? && answer.nil?
        raise ArgumentError, "Approve up to #{MAX_LINES} lines at a time." if entries.length > (input[:leave_repeats_out] == true ? 1000 : MAX_LINES)
        domain.projection_periods = {}
        domain.overlap_context = OverlapDetector::Context.new(household, excluded_revision_id: revision.id)
        check_account_heads!(entries)
        link_accounts!
        plan = ParticipantPlan.new(household, revision, unlinked_account_ids: @linked_now, overlap_context: domain.overlap_context, accounts: @source_accounts)
        if input[:leave_repeats_out] == true
          eligible = plan.repeated_lines.map { |line| line.event.id }
          unless entries.all? { |entry| entry[:decision] == "leave_out" && entry[:expected_head].present? && (eligible.include?(entry[:event_id].to_i) || (plan.line_for(entry[:event_id].to_i)&.done && plan.review_heads[entry[:event_id].to_i]&.approved_version&.disposition == "exclude")) }
            raise Domain::StaleReview, "These lines changed. Please review them one by one."
          end
        end
        check_expected!(plan, entries)
        domain.begin_line_batch!(plan.lines.map(&:event), revision: revision, plan: plan)
        counts = Hash.new(0)
        entries.sort_by { |entry| plan.line_for(entry.fetch(:event_id).to_i)&.event&.position.to_i }.each do |entry|
          apply!(plan, entry, counts)
        end
        domain.flush_line_batch!
        { approved: counts[:approved], left_out: counts[:left_out], unchanged: counts[:unchanged], complete: finish_coverage!(answer) }
      rescue KeyError, TypeError
        raise ArgumentError, "Statement review request is missing required fields"
      ensure
        domain.end_line_batch! if domain.line_batch
        domain.overlap_context = nil
        domain.projection_periods = nil
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
      end

      # What is saved must be exactly what she was shown: the line's kind and category as they were on her screen.
      # Every answer that saves a line as the statement reads it carries that, whether or not the request names the lines
      # it expects; a request that does not say what she saw, or saw something else, saves nothing.
      def check_shown!(line, entry)
        shown = entry[:shown]
        looked = shown.is_a?(Hash) && shown.key?(:category_id) && shown.key?(:event_type) &&
          # A saved line is shown as she saved it (ParticipantPresenter), so compare with what she saved.
          shown[:event_type].to_s == (line.saved&.event_type || line.event.event_type) && shown[:category_id]&.to_i == line.category_id
        raise Domain::StaleReview, "This line changed while you were looking at it. Nothing was saved. Please look again." unless looked
      end

      # Check the account she saw before linking accounts in this request. A first
      # review can itself create the identity; another window's choice cannot be reused.
      def check_account_heads!(entries)
        observed = entries.select { |entry| entry.key?(:expected_head) }
        events = revision.financial_source_events.where(id: observed.map { |entry| entry.fetch(:event_id) }).index_by(&:id)
        observed.each do |entry|
          event = events[entry.fetch(:event_id).to_i] || raise(ActiveRecord::RecordNotFound)
          current = domain.overlap_context.accounts[event.financial_source_account_id]&.approved_version_id
          unless entry[:expected_head].is_a?(Hash) && entry[:expected_head][:account_version_id] == current
            raise Domain::StaleReview, "This line was changed in another window. Nothing was saved. Refresh to review the latest answer."
          end
        end
      end

      def link_accounts!
        @linked_now = []
        accounts = revision.financial_source_accounts.order(:id).to_a
        @source_accounts = accounts.index_by(&:id)
        changes = Array(input[:accounts]).map { |row| row.to_h.deep_symbolize_keys }.index_by { |row| row[:source_account_id].to_i }
        heads = domain.overlap_context.accounts
        # Validate what was displayed before writing any links. Multiple sections
        # of the same new account can reuse the account created in this request.
        accounts.each { |account| check_suggestion!(account, heads[account.id], changes[account.id] || {}) }
        accounts.each do |account|
          head = heads[account.id]
          change = changes[account.id] || {}
          current = head&.approved_version
          next if current && change.empty?

          tracked = current&.source_tracked_account
          selected_id = change[:tracked_account_id] || change[:expected_tracked_account_id]
          selected = domain.tracked_account(selected_id) if selected_id.present?
          basis = selected&.account_basis || change[:account_basis].presence || tracked&.account_basis || account.account_basis
          raise ArgumentError, "Choose whether this is a bank account or a credit card." unless basis.in?(%w[asset liability])
          label = account_label(account, tracked, change, basis)
          existing = account_to_link(account, tracked, selected, change, label, basis)
          facts = statement_facts(account, current, change)
          next if current && existing == tracked && current.statement_facts.symbolize_keys.slice(:period_start_on, :period_end_on) == facts.slice(:period_start_on, :period_end_on)

          raw = { source_account_id: account.id, tracked_account_id: existing&.id, label: label, account_basis: basis,
            base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0, statement_facts: facts, reason: REASON }
          domain.execute("account_link", domain.normalize("account_link", raw))
          domain.overlap_context.refresh!
          @linked_now << account.id unless current
        end
      end

      def check_suggestion!(account, head, change)
        return unless change.key?(:expected_tracked_account_id)

        current = head&.approved_version&.source_tracked_account_id
        label = AccountMatch.default_label(account, account.account_basis)
        suggestion = AccountMatch.suggested(household, label, account.account_basis, account: account) unless current
        expected = change[:expected_tracked_account_id]
        return if expected == (current || suggestion&.id) &&
          (current || suggestion || !AccountMatch.ambiguous?(household, label, account.account_basis, account: account))

        raise Domain::StaleReview, "Your saved accounts changed. Refresh to choose which account this is."
      end

      def account_label(account, tracked, change, basis)
        return tracked.label if tracked && change[:label].blank? && tracked.account_basis == basis

        default = AccountMatch.default_label(account, basis)
        previous = AccountName.parts(tracked&.label)
        last4 = AccountName.parts(change[:label])[:last4] || previous[:last4] || AccountName.parts(default)[:last4]
        AccountName.default_label(change[:label].presence || previous[:name] || default, ("····#{last4}" if last4), basis)
      end

      def account_to_link(account, tracked, selected, change, label, basis)
        return selected if selected
        return tracked if tracked && tracked.label == label && tracked.account_basis == basis
        return if change.key?(:tracked_account_id)
        # Corrections retain the original exact-label behavior. The last-four
        # heuristic is only for a statement that has never had a saved account.
        return AccountMatch.existing(household, label, basis) if tracked && AccountMatch.named?(label)
        return if tracked

        options = { account: account, allow_last_four: change[:label].blank? && !change.key?(:expected_tracked_account_id) }
        if AccountMatch.ambiguous?(household, label, basis, account: account, allow_last_four: !change.key?(:expected_tracked_account_id))
          raise Domain::StaleReview, "Your saved accounts changed. Refresh to choose which account this is."
        end
        AccountMatch.suggested(household, label, basis, **options)
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
        if decision == "pair_transfer"
          return approve_pair!(line, entry, counts)
        elsif decision == "unpair_transfer"
          return unpair!(line, entry, counts)
        end
        identity = domain.overlap_context.accounts[event.financial_source_account_id]&.approved_version
        head = domain.line_head(event)
        facts = facts_for(line, decision, entry[:edit].to_h.deep_symbolize_keys, identity.id, (head&.approved_version if line.done), prior: head&.approved_version)
        if facts[:signed_amount_cents] != event.signed_amount_cents || facts[:posted_on].to_s != event.posted_on.to_s
          candidate = event.dup
          candidate.signed_amount_cents = facts[:signed_amount_cents]
          candidate.posted_on = facts[:posted_on]
          domain.overlap_context.preload!(plan.lines.map(&:event) + [ candidate ], revision.financial_document_import&.checksum_sha256)
        end
        if line.done && same_facts?(head.approved_version, facts)
          counts[:unchanged] += 1
          return
        end
        if (head || entry.key?(:expected_head)) && entry[:expected_head]&.except(:account_version_id) != line.expected_head.except(:account_version_id)
          raise Domain::StaleReview, "This line was changed in another window. Nothing was saved. Refresh to review the latest answer."
        end
        check_allowed!(line, decision, entry)
        stage_and_approve!(event, head, facts)
        counts[decision == "leave_out" ? :left_out : :approved] += 1
      end

      # The pair shown on screen is checked again under the household lock. Never
      # rewrite an approved counterpart; only explicitly reviewed new lines are saved.
      def approve_pair!(line, entry, counts)
        pairs = TransferPairs.new(household)
        existing = pairs.paired(line.event)
        if existing
          members = existing.source_economic_memberships.map(&:source_review_version)
          own = members.find { |version| version.financial_source_event.id == line.event.id }
          other = members.find { |version| version.financial_source_event.id == entry.dig(:transfer_pair, :event_id) }
          retry_matches = own && other && own.supersedes_id == entry.dig(:expected_head, :approved_version_id) &&
            other.source_account_identity_version_id == entry.dig(:transfer_pair, :account_version_id) &&
            (other.id == entry.dig(:transfer_pair, :approved_version_id) || (entry.dig(:transfer_pair, :approved_version_id).nil? && other.supersedes_id.nil?))
          raise Domain::StaleReview, "These lines changed. Please look again." unless retry_matches
          counts[:unchanged] += 2
          return
        end
        pair = pairs.candidate(line.event)
        expected = entry[:transfer_pair]&.slice(:event_id, :approved_version_id, :account_version_id)
        actual = pair && { event_id: pair[:event].id, approved_version_id: pair[:version]&.id, account_version_id: pair[:identity].id }
        raise Domain::StaleReview, "These lines changed. Please look again." unless line.kind == :transfer_pair && actual && expected == actual
        raise Domain::StaleReview, "This line changed. Please look again." unless entry[:expected_head] == line.expected_head
        check_shown!(line, entry)
        identity = domain.account_heads.find_by!(financial_source_account_id: line.event.financial_source_account_id).approved_version
        facts = ParticipantPlan.facts_as_read(line.event, identity_id: identity.id, merchant: line.merchant, category_id: nil).merge(event_type: line.event.event_type == "debt_payment" ? "debt_payment" : "transfer", purchase_amount_cents: nil)
        stage_and_approve!(line.event, domain.heads.find_by(financial_source_event: line.event), facts)
        unless pair[:version]
          other = pair[:event]
          other_facts = ParticipantPlan.facts_as_read(other, identity_id: pair[:identity].id, merchant: ParticipantPlan.merchant_for(other), category_id: nil).merge(event_type: other.event_type == "debt_payment" ? "debt_payment" : "transfer", purchase_amount_cents: nil)
          stage_and_approve!(other, domain.heads.find_by(financial_source_event: other), other_facts)
        end
        versions = [ line.event, pair[:event] ].map { |event| domain.heads.find_by!(financial_source_event: event).approved_version }
        raw = { kind: "transfer", base_version_id: nil, base_lock_version: 0, reason: REASON,
          members: versions.map { |version| { source_review_version_id: version.id, role: "movement", allocation_cents: version.signed_amount_cents.abs } } }
        domain.execute("economic_link", domain.normalize("economic_link", raw))
        counts[:approved] += pair[:version] ? 1 : 2
      end

      def unpair!(line, entry, counts)
        group = TransferPairs.new(household).paired(line.event)
        raise Domain::StaleReview, "These lines changed. Please look again." unless group && entry[:expected_head] == line.expected_head
        group.source_economic_memberships.each do |member|
          version = member.source_review_version
          facts = version.reviewed_facts.symbolize_keys.except(:matched_version_id).merge(external_reference: "unpaired-transfer:#{version.financial_source_event.id}")
          stage_and_approve!(version.financial_source_event, version.source_review_head, facts)
        end
        counts[:approved] += 2
      end

      def check_allowed!(line, decision, entry)
        stale = Domain::StaleReview.new("This line changed while you were reviewing it. Nothing was saved. Refresh and try again.")
        case decision
        when "own_account", "someone_else"
          raise stale unless !line.done && line.kind.in?(%i[person_payment person_payment_duplicate])
          raise stale if line.kind == :person_payment_duplicate && line.overlaps.any? { |row| row[:strength] == "strong" && row[:approved_version_id] }
          check_shown!(line, entry)
        when "as_read"
          # "Yes" to "Does this refund go back to Clothing?" saves that category, also for a saved refund that counted nowhere.
          refund_answer = line.kind == :refund_category && line.category_id.present? && (!line.done || line.without_category)
          raise stale unless refund_answer || (!line.done && (line.ready? || line.kind.in?(%i[transfer card_payment refund still_category suggested_category])))
          # "Yes" to "Still Dining out?" confirms the category she was asked about and nothing else: the line keeps its kind.
          check_shown!(line, entry)
        when "different"
          raise stale unless line.kind.in?(%i[duplicate same_purchase]) || (line.done && domain.line_head(line.event)&.approved_version&.matched_transaction_id)
          raise ArgumentError, "That line is already in your numbers, so it can only be left out." if line.overlaps.any? { |row| row[:strength] == "strong" && row[:approved_version_id] }
          check_shown!(line, entry)
        when "same_purchase"
          # "Same purchase" names the purchase she was shown; one that changed since is asked about again.
          raise stale if entry[:edit].present?
          raise stale unless line.kind == :same_purchase && !line.done && entry[:match_transaction_id].to_i == line.purchase_match&.transaction&.id
          check_shown!(line, entry)
        end
      end

      # prior: the line's approved version even while unfinished, so an answer she already gave ("different charge") stands.
      def facts_for(line, decision, edit, identity_id, saved = nil, prior: nil)
        base = ParticipantPlan.facts_as_read(line.event, identity_id: identity_id, merchant: line.merchant, category_id: line.category_id)
        # A line she already saved changes from what she saved, never from the statement as first read:
        # choosing a category must not undo a corrected amount, name, date or kind, or her "different charge".
        if saved&.disposition == "include"
          base = base.merge(saved.reviewed_facts.slice(:event_type, :signed_amount_cents, :purchase_amount_cents, :posted_on, :authorized_on, :merchant, :overlap_disposition, :external_reference))
        end
        # Her "different charge" or "different purchase" was saved on the way to this question; keep it.
        cleared = line.kind == :person_payment_duplicate || prior&.external_reference.to_s.start_with?("overlap-cleared:", "ownership-needed:")
        case decision
        when "own_account" then base.merge(event_type: base[:event_type] == "debt_payment" ? "debt_payment" : "transfer", purchase_amount_cents: nil, budget_category_id: nil, external_reference: "own-account:#{line.event.id}", overlap_disposition: cleared ? "distinct" : base[:overlap_disposition])
        when "someone_else"
          category = family_support_category!
          base.merge(event_type: "purchase", purchase_amount_cents: base[:signed_amount_cents].abs, budget_category_id: category.id, external_reference: "sent-to-someone:#{line.event.id}", overlap_disposition: cleared ? "distinct" : base[:overlap_disposition])
        when "as_read" then line.kind == :refund_category ? base.merge(budget_category_id: line.category_id) : base
        when "different"
          if TransferPairs.person_payment?(line.event, line.merchant)
            # No category or spending projection until the remaining questions are answered.
            base.merge(overlap_disposition: "distinct", budget_category_id: nil, external_reference: "#{line.kind == :duplicate ? 'overlap-cleared' : 'ownership-needed'}:#{line.event.id}")
          else
            base.merge(overlap_disposition: "distinct")
          end
        # The same purchase as one she confirmed: the line is the bank's record of it and counts nowhere itself.
        # No match any more (the purchase changed) is refused as stale by check_allowed!, never saved.
        when "same_purchase" then base.merge(disposition: "match", matched_transaction_id: line.purchase_match&.transaction&.id, budget_category_id: nil, overlap_disposition: "match")
        when "leave_out" then base.merge(disposition: "exclude", purchase_amount_cents: nil, budget_category_id: nil, overlap_disposition: "excluded")
        else
          facts = edited_facts(base, edit, saved: saved&.disposition == "include")
          if !line.done && TransferPairs.person_wording?(line.event, line.merchant) && facts[:signed_amount_cents].to_i.negative?
            # Spending in a category she chose is ordinary spending; only "someone else" (no category) is family support.
            if facts[:event_type] == "purchase" && facts[:budget_category_id].nil?
              facts = facts.merge(budget_category_id: family_support_category!.id, external_reference: "sent-to-someone:#{line.event.id}")
            elsif facts[:event_type].in?(%w[transfer debt_payment])
              facts = facts.merge(event_type: base[:event_type] == "debt_payment" ? "debt_payment" : facts[:event_type], external_reference: "own-account:#{line.event.id}")
            end
          end
          facts
        end
      end

      def family_support_category!
        category = household.budget_categories.find_by("lower(name) = ?", "family support")
        if category && !category.active?
          raise ArgumentError, "Restore Family support in Budget, then save this answer."
        end
        unless category
          category = household.budget_categories.create!(name: "Family support", stack_key: "non_discretionary")
          domain.projection_periods&.clear
        end
        domain.line_batch[:categories][category.id] = category if domain.line_batch
        category
      end

      # saved: base holds what she saved, not the statement as first read.
      def edited_facts(base, edit, saved: false)
        kind = edit[:kind].to_s
        type = KINDS.fetch(kind) { raise ArgumentError, "Choose what this line was" }
        # "Spending" covers fees, interest and cash withdrawals too: choosing a category for one must not turn it into a purchase.
        type = base[:event_type] if kind == "spending" && base[:event_type].in?(ParticipantPlan::EXPENSE_TYPES)
        if base[:signed_amount_cents].nil? && !edit[:money_direction].in?(%w[in out])
          raise ArgumentError, "Choose whether this was money out or money in."
        end
        if (edit[:money_direction] == "in" && kind.in?(%w[spending cash])) || (edit[:money_direction] == "out" && kind.in?(%w[money_in refund]))
          raise ArgumentError, "Choose a kind that matches money out or money in."
        end
        cents = edit.key?(:amount_cents) ? edit[:amount_cents] : base[:signed_amount_cents]&.abs
        raise ArgumentError, "Enter the amount for this line" unless cents.is_a?(Integer) && cents.positive?
        signed = case kind
        when "spending", "cash" then -cents
        when "moved", "card"
          direction = edit[:money_direction]
          raise ArgumentError, "Choose money in or money out." if direction && !direction.in?(%w[in out])
          direction == "in" || (direction.nil? && base[:signed_amount_cents].to_i.positive?) ? cents : -cents
        else cents
        end
        merchant = edit[:merchant].to_s.squish.presence || base[:merchant]
        expense = signed.negative? && type.in?(FinancialSourceEvent::EXPENSE_TYPES)
        posted_on = edit[:posted_on].presence || base[:posted_on]
        # The same amount on the same day keeps her earlier "different charge"; a new amount or day is asked about again.
        same_charge = signed == base[:signed_amount_cents] && posted_on.to_s == base[:posted_on].to_s && base[:overlap_disposition] == "distinct"
        # A saved purchase whose total differs from the money that moved (part paid another way) keeps that total when only its category changes.
        purchase = saved && signed == base[:signed_amount_cents] && base[:purchase_amount_cents].present? ? base[:purchase_amount_cents] : cents
        # A refund carries a category only when she says which one it goes back to; otherwise it follows the purchase it refunds.
        refund = type == "refund" && signed.positive?
        base.merge(disposition: "include", event_type: type, signed_amount_cents: signed, posted_on: posted_on, merchant: merchant,
          purchase_amount_cents: expense ? purchase : nil, budget_category_id: expense || refund ? edit[:category_id].presence&.to_i : nil, overlap_disposition: same_charge ? "distinct" : "new")
      end

      def same_facts?(version, facts)
        return false unless version
        keys = %i[disposition event_type signed_amount_cents purchase_amount_cents posted_on merchant budget_category_id overlap_disposition matched_transaction_id]
        version.reviewed_facts.slice(*keys).stringify_keys == facts.slice(*keys).stringify_keys
      end

      def stage_and_approve!(event, head, facts)
        head = domain.line_head(event) if domain.line_batch
        pending = domain.pending_draft(head)
        raw = { event_id: event.id, base_version_id: head&.approved_version_id, base_lock_version: head&.lock_version || 0,
          expected_pending_draft: pending && { id: pending.id, lock_version: pending.lock_version, digest: pending.digest },
          facts: facts, projection: projection_for(event, facts), reason: REASON }
        draft = domain.execute("stage", domain.normalize("stage", raw))
        domain.execute("approve", domain.normalize("approve", draft_id: draft.id, draft_lock_version: draft.lock_version, draft_digest: draft.digest))
      end

      # Counts as spending only when the participant approved a categorized purchase outflow.
      def projection_for(event, facts)
        actuals = domain.actuals_for(event)
        actual = actuals.one? ? actuals.first : nil
        category = facts[:budget_category_id] && domain.category(facts[:budget_category_id])
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
        return false unless domain.line_batch[:events].any? || answer.present?

        state = ApprovalState.new(household, revision).call
        return false if (state[:deficiencies] & NOT_REVIEWED).any? || state[:pending_corrections].positive?
        asked = CoverageQuestion.text(revision, deficiencies: state[:deficiencies]).present?
        said = answer || CoverageQuestion.answer(revision)
        return false if asked && said.nil?
        # "Something's missing" always stands, even when the statement's own totals would not have asked.
        accounted = said != "something_missing" && (!asked || said == "nothing_missing")
        last = SourceRevisionApproval.where(household: household, financial_extraction_revision: revision).order(version_number: :desc).first
        return true if last&.digest == state[:content_digest] && last.coverage_attestation["all_document_rows_accounted"] == accounted
        accounts = domain.line_batch[:source_accounts].values.sort_by(&:id).map do |account|
          identity = domain.overlap_context.accounts[account.id].approved_version
          { source_account_id: account.id, identity_version_id: identity.id, period_start_on: identity.statement_facts["period_start_on"],
            period_end_on: identity.statement_facts["period_end_on"], all_rows_accounted: accounted }
        end
        raw = { revision_id: revision.id, requested_status: state[:deficiencies].empty? && accounted ? "complete" : "qualified", expected_digest: state[:content_digest],
          reason: REASON, coverage_attestation: { all_document_rows_accounted: accounted, accounts: accounts } }
        domain.execute("revision_approve", domain.normalize("revision_approve", raw))
        true
      end
    end
  end
end
