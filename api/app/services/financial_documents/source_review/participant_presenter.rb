module FinancialDocuments
  module SourceReview
    # Reviewed facts are separate from immutable extraction and erasable evidence.
    class ParticipantPresenter
      def initialize(household, revision, user: nil)
        @household, @revision, @user = household, revision, user
      end

      def context(event_ids:)
        heads = SourceReviewHead.where(household: household, financial_source_event_id: event_ids)
          .includes(:approved_version, source_review_drafts: []).index_by(&:financial_source_event_id)
        account_heads = SourceAccountReviewHead.where(household: household, financial_source_account_id: revision.financial_source_accounts.select(:id))
          .includes(approved_version: :source_tracked_account).index_by(&:financial_source_account_id)
        approval = SourceRevisionApproval.where(household: household, financial_extraction_revision: revision).order(version_number: :desc).first
        state = ApprovalState.new(household, revision).call
        {
          schema_version: 1,
          transfer_pairs: EconomicLinker.valid_current_versions(household).select { |group| group.kind == "transfer" }.filter_map do |group|
            members = group.source_economic_memberships.map(&:source_review_version)
            local = members.select { |version| event_ids.include?(version.financial_source_event.id) }
            next if local.empty?
            { event_id: local.first.financial_source_event.id, expected_head: head_state(local.first.source_review_head),
              accounts: members.map { |version| AccountNumberMask.display(version.source_tracked_account.label) } }
          end,
          actor_scope: { user_id: @user&.id, household_id: household.id },
          rows: event_ids.index_with do |id|
            head = heads[id]
            { head: head_state(head), approved: head&.approved_version && record(head.approved_version),
              pending: head&.source_review_drafts&.pending&.first&.then { |draft| record(draft) } }
          end,
          accounts: revision.financial_source_accounts.order(:id).map do |account|
            head = account_heads[account.id]
            { source_account_id: account.id, head: head_state(head), approved: head&.approved_version && record(head.approved_version),
              **account_details(account, head&.approved_version&.source_tracked_account) }
          end,
          coverage: state,
          approved_coverage: approval && { id: approval.id, digest: approval.digest, status: approval.coverage_status,
            current: approval.digest == state[:content_digest], deficiencies: approval.deficiencies },
          economic_groups: EconomicLinker.current_versions(household).select { |group| group.source_economic_memberships.any? { |member| event_ids.include?(member.source_review_version.financial_source_event.id) } }.map do |group|
            { id: group.source_economic_group_id, head: head_state(group.source_economic_group),
              approved: { id: group.id, kind: group.kind, digest: group.digest, version_number: group.version_number, reason: group.reason,
                current: group.source_economic_memberships.all? { |member| member.source_review_version.source_review_head.approved_version_id == member.source_review_version_id && member.source_review_version.source_account_identity_version.source_account_review_head.approved_version_id == member.source_review_version.source_account_identity_version_id },
                members: group.source_economic_memberships.map { |member| { role: member.role, allocation_cents: member.allocation_cents, record: record(member.source_review_version) } } } }
          end,
          categories: household.budget_categories.active.order(:sort_order, :id).pluck(:id, :name).map { |id, name| { id: id, name: name } },
          plan: plan_summary(state)
        }
      end

      # What the participant sees first: how many lines look right, and the few that need an answer.
      def plan_summary(state = ApprovalState.new(household, revision).call)
        plan = ParticipantPlan.new(household, revision)
        names = household.budget_categories.active.pluck(:id, :name).to_h
        dates = plan.lines.filter_map { |line| line.event.posted_on }
        totals = CoverageQuestion.totals_check(revision)
        # "ready" is exactly what "Approve the rest" will save: each line's category (and how it was chosen) is shown to her and sent back.
        bases = revision.financial_source_accounts.map do |account|
          SourceAccountReviewHead.find_by(financial_source_account: account)&.approved_version&.source_tracked_account&.account_basis || account.account_basis
        end
        file_answer_available = revision.financial_document_import&.source_available? == true && !SpreadsheetSignAnswer.saved_decisions?(revision)
        target_rows = revision.coverage["signed_amount_target_rows"]
        target_accounts = plan.lines.select { |line| target_rows ? target_rows.include?(line.event.row_identity) : line.event.limitations.include?("transaction_direction_unclear") }.map { |line| line.event.financial_source_account_id }.uniq
        file_question = revision.coverage["signed_amount_question"] == true && file_answer_available && bases.uniq.length == 1 && target_accounts.one?
        account_questions = file_question ? [] : account_sign_questions
        # Lines wait until every account's question is answered: approving one would close the others.
        { signed_amount_single_sign: revision.coverage["signed_amount_single_sign"], signed_amount_balance_factor: revision.coverage["signed_amount_balance_factor"], signed_amount_question: file_question || account_questions.any? { |question| question[:answerable] && question[:choice].nil? },
          signed_amount_answerable: revision.coverage["signed_amount_answerable"] == true && file_answer_available, account_sign_questions: account_questions,
          sign_effect: sign_effect(plan), total: plan.lines.length, done: plan.lines.count(&:done), without_category: plan.lines.count(&:without_category), spending: ParticipantProgress.new(household, revision).spending_totals, ready_event_ids: plan.ready_ids, totals_check: totals,
          ready: plan.lines.select { |line| line.ready? && !line.done }.map { |line| { event_id: line.event.id, event_type: line.event.event_type, category_id: line.category_id, category_name: names[line.category_id], as_before: line.as_before,
            merchant: MerchantNormalizer.call(line.merchant), editable_merchant: line.merchant, signed_amount_cents: line.event.signed_amount_cents, posted_on: line.event.posted_on&.iso8601, expected_head: line.expected_head, informational: line.event.row_kind == "informational" } },
          coverage: { question: CoverageQuestion.text(revision, check: totals, deficiencies: state[:deficiencies]), answer: CoverageQuestion.answer(revision), version_id: CoverageQuestion.latest(revision)&.id },
          first_on: dates.min&.iso8601, last_on: dates.max&.iso8601,
          store_groups: store_groups(plan, names),
          repeated_line_ids: plan.repeated_lines.map { |line| line.event.id },
          category_groups: plan.category_groups.map { |group| group.map { |line| line.event.id } },
          attention: plan.attention.map { |line| attention_row(line, names) } }
      end

      def store_groups(plan, names)
        local = plan.category_lines
        return [] if local.empty?
        keys = local.map { |line| MerchantNormalizer.call(line.merchant).to_s.downcase.squish }.to_set
        rows = local.map { |line| attention_row(line, names).merge(revision_id: revision.id, statement_name: revision.financial_document_import&.filename) }
        household.financial_document_imports.find_each do |document|
          next if document.id == revision.financial_document_import_id
          next unless document.financial_generation == household.financial_generation
          other = document.financial_extraction_revisions.order(revision_number: :desc, id: :desc).first
          next unless other
          other_plan = ParticipantPlan.new(household, other)
          other_plan.category_lines.each do |line|
            next unless keys.include?(MerchantNormalizer.call(line.merchant).to_s.downcase.squish)
            next unless line.expected_head[:account_version_id]
            rows << attention_row(line, names).merge(revision_id: other.id, statement_name: document.filename)
          end
        end
        rows.group_by { |row| MerchantNormalizer.call(row[:merchant]).to_s.downcase.squish }.values.select { |group| group.length > 1 }.map { |group| group.first(1000) }
      end

      def sign_effect(plan)
        coverage = revision.coverage
        return "You chose to answer money out or money in for each line." if coverage["signed_amount_choice"] == "individual"
        convention = coverage["signed_amount_convention"]
        convention = coverage["signed_amount_derived_convention"] if convention.nil?
        return if convention.nil?
        answered = coverage["signed_amount_convention_source"] == "answer"
        targets = coverage["signed_amount_target_rows"]
        lines = plan.lines.select { |line| (!targets || targets.include?(line.event.row_identity)) && line.event.signed_amount_cents.present? }
        count = lines.length
        rule = case coverage["signed_amount_choice"]
        when "all_out" then "You said every amount is money out."
        when "all_in" then "You said every amount is money in."
        else answered ? "You said spending is shown as #{convention ? 'negative' : 'positive'}." : "The balance column shows spending as #{convention ? 'negative' : 'positive'}."
        end
        "#{rule} That set the direction of #{count} #{count == 1 ? 'line' : 'lines'}."
      end

      # One money-direction question per account of a multi-account file, in file order, with what her answer did.
      def account_sign_questions
        SpreadsheetSignAnswer.account_questions(revision).map do |question|
          account = question[:account]
          tracked = SourceAccountReviewHead.find_by(financial_source_account: account)&.approved_version&.source_tracked_account
          basis = tracked&.account_basis || account.account_basis
          label = tracked&.label || AccountMatch.default_label(account, basis)
          choice = question[:answer]&.fetch("choice", nil)
          lines = question[:lines].count { |event| event.signed_amount_cents.present? }
          { source_account_id: account.id, label: label, account_basis: basis, single_sign: question[:single_sign], choice: choice, answerable: question[:answerable],
            lines: question[:answer] ? lines : 0, effect: question[:answer] && account_sign_effect(label, question[:answer], lines) }
        end
      end

      def account_sign_effect(label, answer, count)
        return "You chose to answer money out or money in for each line in #{label}." if answer["choice"] == "individual"
        rule = case answer["choice"]
        when "all_out" then "You said every amount in #{label} is money out."
        when "all_in" then "You said every amount in #{label} is money in."
        else "You said spending in #{label} is shown as #{answer['negative_is_money_out'] ? 'negative' : 'positive'}."
        end
        "#{rule} That set the direction of #{count} #{count == 1 ? 'line' : 'lines'}."
      end

      def record(subject, include_matched_target: true)
        case subject
        when SourceReviewDraft
          subject.attributes.slice("id", "status", "lock_version", "digest", "projection", "reason", "base_version_id", "base_head_lock_version").merge(
            facts: shown_facts(subject.facts),
            recognized_account: recognized_account(subject.facts["source_account_identity_version_id"]),
            matched_target: include_matched_target ? matched_target(subject.facts["matched_version_id"]) : nil)
        when SourceReviewVersion
          { id: subject.id, digest: subject.digest, version_number: subject.version_number, facts: shown_facts(subject.reviewed_facts),
            projection: subject.projection, reason: subject.reason,
            source: { document_import_id: subject.financial_source_event.financial_extraction_revision.financial_document_import_id,
              filename: subject.financial_source_event.financial_extraction_revision.financial_document_import&.filename,
              locator: subject.financial_source_event.locator, source_available: subject.financial_source_event.financial_extraction_revision.financial_document_import&.source_available? == true },
            actual: actual(subject), recognized_account: recognized_account(subject.source_account_identity_version_id),
            current: current_version?(subject), matched_target: include_matched_target ? matched_target(subject.matched_version_id) : nil
          }.merge(subject.matched_transaction_id ? { matched_purchase: matched_purchase(subject) } : {})
        when SourceAccountIdentityVersion
          { id: subject.id, digest: subject.digest, version_number: subject.version_number, statement_facts: subject.statement_facts,
            tracked_account: { id: subject.source_tracked_account_id, label: subject.source_tracked_account.label,
              account_basis: subject.source_tracked_account.account_basis, account_id: subject.source_tracked_account.account_id } }
        else
          { id: subject.id, digest: subject.try(:digest) }
        end
      end

      private

      attr_reader :household, :revision

      # Lines approved before long account numbers were hidden still store the statement's words; she reads them masked.
      def shown_facts(facts)
        key = facts.key?(:merchant) ? :merchant : "merchant"
        facts.is_a?(Hash) && facts[key].is_a?(String) ? facts.merge(key => AccountNumberMask.display(facts[key])) : facts
      end

      def attention_row(line, names)
        event = line.event
        # A copy of a row she already approved can only be left out; it cannot be counted twice.
        answers = line.kind.in?(%i[duplicate person_payment_duplicate]) && line.overlaps.any? { |row| row[:strength] == "strong" && row[:approved_version_id] } ? ParticipantPlan::ANSWERS.fetch(line.kind).first(1) : ParticipantPlan::ANSWERS.fetch(line.kind)
        question = line.kind == :still_category ? "Still #{names[line.category_id]}?" : ParticipantPlan::QUESTIONS.fetch(line.kind)
        question = "Was this #{names[line.category_id]}?" if line.kind == :suggested_category
        question = "#{question} Category: #{names[line.category_id] || 'None chosen'}." if line.kind == :correction
        question = line.purchase_match.question if line.kind == :same_purchase
        # A refund names where its money goes back: the purchase's category, or the one she chose for this store before.
        refund_names = Array(line.refund_to).filter_map { |id| category_names[id] }
        question = "Is this a refund? It goes back to #{refund_names.to_sentence}." if line.kind == :refund && refund_names.any?
        if line.kind == :refund_category && line.category_id
          question = "Does this refund go back to #{names[line.category_id]}?"
          answers = ParticipantPlan::ANSWERS[:suggested_category]
        end
        # A saved line shows what she saved (her corrected amount, name, date and kind), not the statement as first read.
        saved = line.saved
        { raw_description: AccountNumberMask.display(event.financial_source_evidence&.payload&.dig("raw_description")), event_id: event.id, kind: line.kind, event_type: saved&.event_type || event.event_type, question: question, answers: answers,
          amount_cents: saved ? saved.signed_amount_cents&.abs : HouseholdFinance::Money.document_cents(event.financial_source_evidence&.payload&.fetch("source_amount_text", nil), negative_as_magnitude: true),
          merchant: MerchantNormalizer.call(saved&.merchant.presence || line.merchant), editable_merchant: AccountNumberMask.display(saved&.merchant.presence || line.merchant), posted_on: (saved ? saved.posted_on : event.posted_on)&.iso8601, signed_amount_cents: saved ? saved.signed_amount_cents : event.signed_amount_cents,
          disposition: saved&.disposition, purchase_amount_cents: saved&.purchase_amount_cents,
          category_id: line.category_id, category_name: names[line.category_id] || (refund_names.to_sentence.presence if line.kind == :refund), expected_head: line.expected_head,
          recipient_question: !line.kind.in?(%i[correction money_in_source]) && !line.done && TransferPairs.person_wording?(event, line.merchant) && !event.signed_amount_cents.to_i.positive?,
          transfer_pair: line.pair && { event_id: line.pair[:event].id, approved_version_id: line.pair[:version]&.id, account_version_id: line.pair[:identity].id,
            description: AccountNumberMask.display(ParticipantPlan.merchant_for(line.pair[:event])),
            account: AccountNumberMask.display(line.pair[:identity].source_tracked_account.label), posted_on: line.pair[:date].iso8601, signed_amount_cents: line.pair[:amount] } }
          .merge(line.kind == :same_purchase ? { purchase_match: line.purchase_match.summary } : {})
      end

      # A refund can go back to a purchase's category that is no longer active, so this includes every category.
      def category_names
        @category_names ||= household.budget_categories.pluck(:id, :name).to_h
      end

      def account_details(account, tracked)
        choices = (@account_choices ||= AccountMatch.candidates(household).to_a)
        if tracked
          return AccountName.parts(tracked.label).merge(choices: choices.reject { |choice| choice.id == tracked.id }.map { |choice| account_choice(choice) })
        end

        basis = account.account_basis
        label = AccountMatch.default_label(account, basis)
        name = AccountName.parts(label)
        eligible = choices.select { |choice| choice.account_basis == basis || basis == "unknown" }
        suggested = AccountMatch.suggested(household, label, basis, account: account)
        needs_choice = !suggested && (basis == "unknown" || name[:last4].nil? || AccountMatch.ambiguous?(household, label, basis, account: account))
        name.merge(needs_choice: needs_choice, suggested: suggested && account_choice(suggested), choices: eligible.map { |choice| account_choice(choice) })
      end

      def account_choice(account)
        { id: account.id, account_basis: account.account_basis, **AccountName.parts(account.label) }
      end

      def head_state(head)
        { id: head&.id, approved_version_id: head&.approved_version_id, lock_version: head&.lock_version || 0 }
      end

      def recognized_account(identity_id)
        identity = SourceAccountIdentityVersion.where(household: household).find_by(id: identity_id)
        return unless identity
        { identity_version_id: identity.id, tracked_account_id: identity.source_tracked_account_id,
          label: identity.source_tracked_account.label, account_basis: identity.source_tracked_account.account_basis,
          account_id: identity.source_tracked_account.account_id, current: identity.source_account_review_head.approved_version_id == identity.id }
      end

      def matched_target(version_id)
        target = SourceReviewVersion.where(household: household).find_by(id: version_id)
        record(target, include_matched_target: false) if target
      end

      # The purchase she said this line is: it counts, with its own categories, and the line doesn't.
      def matched_purchase(version)
        transaction = version.matched_transaction_id && household.household_transactions.includes(transaction_splits: :budget_category).find_by(id: version.matched_transaction_id)
        return unless transaction

        ConfirmedPurchaseMatch::Match.new(transaction: transaction, score: nil).summary.merge(current: ConfirmedPurchaseMatch.current?(household, version))
      end

      def current_version?(version)
        version.source_review_head.approved_version_id == version.id &&
          version.source_account_identity_version.source_account_review_head.approved_version_id == version.source_account_identity_version_id
      end

      def actual(version)
        transactions = household.household_transactions.where(financial_source_event: version.financial_source_event, status: %w[confirmed reconciled]).order(:id).limit(2).to_a
        return unless transactions.one?
        transaction = transactions.first
        { id: transaction.id, amount_cents: transaction.total_amount_cents,
          digest: ProjectionCorrector.snapshot_digest(transaction) }
      end
    end
  end
end
