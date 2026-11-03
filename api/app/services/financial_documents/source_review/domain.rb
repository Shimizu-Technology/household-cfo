module FinancialDocuments
  module SourceReview
    # Only operation classes expose these mutations. Every execution rechecks
    # the actual participant under the same household lock as financial writes.
    class Domain
      StaleReview = Class.new(ArgumentError)
      attr_reader :household, :user

      def initialize(household, user: nil)
        @household, @user = household, user
      end

      def authorize!(subject = nil)
        actor = user && User.lock.find_by(id: user.id)
        membership = actor && household.household_memberships.lock.find_by(user_id: actor.id)
        allowed = actor&.participant? && membership&.role.in?(%w[owner partner])
        allowed &&= subject.household_id == household.id if subject
        raise ArgumentError, "Only a current participant with writable household access can approve source records." unless allowed
      end

      def normalize(action, raw)
        input = raw.to_h.deep_symbolize_keys
        case action.to_s
        when "account_link"
          source_account(input.fetch(:source_account_id))
          tracked = tracked_account(input[:tracked_account_id]) if input[:tracked_account_id]
          account = household.accounts.find(input[:account_id]) if input[:account_id]
          raise ArgumentError, "The selected canonical account has a different linked household account" if tracked && account && tracked.account_id != account.id
          basis = tracked&.account_basis || input.fetch(:account_basis).to_s
          raise ArgumentError, "Choose asset or liability account basis" unless basis.in?(%w[asset liability])
          { source_account_id: input.fetch(:source_account_id).to_i, tracked_account_id: tracked&.id, account_id: tracked ? tracked.account_id : account&.id, account_basis: basis,
            label: tracked&.label || required_text(input[:label], 120), base_version_id: nullable_id(input.fetch(:base_version_id)), base_lock_version: integer(input.fetch(:base_lock_version)),
            statement_facts: statement_facts(input.fetch(:statement_facts)), reason: required_text(input[:reason], 500) }
        when "stage"
          event = source_event(input.fetch(:event_id))
          { event_id: event.id, base_version_id: nullable_id(input.fetch(:base_version_id)), base_lock_version: integer(input.fetch(:base_lock_version)),
            expected_pending_draft: input[:expected_pending_draft]&.to_h&.symbolize_keys&.slice(:id, :lock_version, :digest),
            facts: reviewed_facts(event, input.fetch(:facts)), projection: projection(input.fetch(:projection, { action: "none" })), reason: required_text(input[:reason], 500) }
        when "approve", "cancel"
          draft = drafts.find(input.fetch(:draft_id))
          { draft_id: draft.id, draft_lock_version: integer(input.fetch(:draft_lock_version)), draft_digest: input.fetch(:draft_digest).to_s }
        when "project"
          version = versions.find(input.fetch(:version_id))
          projection_input = projection(input.fetch(:projection))
          raise ArgumentError, "Choose an explicit projection action" if projection_input[:action] == "none"
          { version_id: version.id, expected_version_digest: input.fetch(:expected_version_digest).to_s,
            projection: projection_input.merge(reason: required_text(input[:reason], 500)) }
        when "revision_approve"
          revision(input.fetch(:revision_id))
          status = input.fetch(:requested_status).to_s
          coverage = input.fetch(:coverage_attestation).to_h.deep_symbolize_keys
          accounts = Array(coverage[:accounts]).map do |row|
            row = row.to_h.deep_symbolize_keys
            identity = identities.find(row.fetch(:identity_version_id))
            { source_account_id: source_account(row.fetch(:source_account_id)).id, identity_version_id: identity.id,
              period_start_on: coverage_date(row.fetch(:period_start_on), identity, "period_start_on", status),
              period_end_on: coverage_date(row.fetch(:period_end_on), identity, "period_end_on", status), all_rows_accounted: row[:all_rows_accounted] == true }
          end
          raise ArgumentError, "An account can only be attested once" unless accounts.pluck(:source_account_id).uniq.length == accounts.length
          { revision_id: input.fetch(:revision_id).to_i, requested_status: status,
            expected_digest: input.fetch(:expected_digest).to_s, reason: required_text(input[:reason], 500),
            coverage_attestation: { accounts: accounts, all_document_rows_accounted: coverage[:all_document_rows_accounted] == true } }
        when "economic_link"
          members = Array(input.fetch(:members)).map do |row|
            row = row.to_h.deep_symbolize_keys
            { source_review_version_id: versions.find(row.fetch(:source_review_version_id)).id, role: row.fetch(:role).to_s, allocation_cents: cents!(row.fetch(:allocation_cents), positive: true) }
          end.sort_by { |row| [ row[:source_review_version_id], row[:role] ] }
          raise ArgumentError, "Choose distinct source versions" unless members.pluck(:source_review_version_id).uniq.length == members.length
          raise ArgumentError, "Economic linking requires between two and twelve movements" unless members.length.between?(2, 12)
          group = groups.find(input[:group_id]) if input[:group_id]
          { group_id: group&.id, base_version_id: nullable_id(input.fetch(:base_version_id)), base_lock_version: integer(input.fetch(:base_lock_version)),
            kind: input.fetch(:kind).to_s, members: members, reason: required_text(input[:reason], 500) }
        else raise ArgumentError, "Unsupported source review action"
        end
      rescue KeyError, TypeError
        raise ArgumentError, "Source review request is missing or has invalid required fields"
      end

      def snapshot(action, input)
        case action.to_s
        when "account_link"
          head = account_heads.find_by(financial_source_account_id: input[:source_account_id])
          { source_account_id: input[:source_account_id], head: head_state(head) }
        when "stage"
          event_snapshot(source_event(input[:event_id]), input[:facts], input[:projection])
        when "approve", "cancel"
          draft = drafts.find(input[:draft_id])
          { draft: draft_state(draft), event: event_snapshot(draft.source_review_head.financial_source_event, draft.facts.deep_symbolize_keys, draft.projection.deep_symbolize_keys) }
        when "project"
          version = versions.find(input[:version_id])
          { version: version_state(version), projection_id: version.source_projection_revision&.id,
            event: event_snapshot(version.financial_source_event, version.attributes.symbolize_keys.merge(source_account_identity_version_id: version.source_account_identity_version_id), input[:projection]),
            economic_links: EconomicLinker.valid_current_versions(household).map { |group| [ group.id, group.digest ] } }
        when "revision_approve"
          ApprovalState.new(household, revision(input[:revision_id])).call
        when "economic_link"
          group = groups.find(input[:group_id]) if input[:group_id]
          { group: head_state(group), rows: input[:members].map { |row| version_state(versions.find(row[:source_review_version_id])) },
            allocations_digest: digest(EconomicLinker.active_memberships(household).map { |m| [ m.id, m.source_review_version_id, m.allocation_cents ] }) }
        end
      end

      def execute(action, input)
        ApplicationRecord.transaction do
          household.lock!
          authorize!
          affected_revision_ids = revision_ids(action, input)
          lock_revisions!(affected_revision_ids)
          result = case action.to_s
          when "account_link" then link_account!(input)
          when "stage" then stage!(input)
          when "approve" then approve!(input)
          when "cancel" then cancel!(input)
          when "project" then project!(input)
          when "revision_approve" then RevisionApprover.new(self, revision(input[:revision_id]), input).call
          when "economic_link" then EconomicLinker.new(self, input).call
          end
          affected_revision_ids.each { |id| mark_review_pending!(revision(id)) } if action.to_s.in?(%w[account_link approve economic_link])
          result
        end
      end

      def source_event(id)
        FinancialSourceEvent.where(household_id: household.id).find(id).tap { |event| HouseholdFinance::FinancialGenerationGuard.source!(event.financial_extraction_revision.financial_document_import) }
      end

      def source_account(id)
        FinancialSourceAccount.where(household_id: household.id).find(id).tap { |account| HouseholdFinance::FinancialGenerationGuard.source!(account.financial_extraction_revision.financial_document_import) }
      end

      def revision(id)
        FinancialExtractionRevision.where(household_id: household.id).find(id).tap { |revision| HouseholdFinance::FinancialGenerationGuard.source!(revision.financial_document_import) }
      end

      def current_revisions = FinancialExtractionRevision.where(household_id: household.id, financial_document_import_id: household.financial_document_imports.current_picture.select(:id))
      def current_events = FinancialSourceEvent.where(household_id: household.id, financial_extraction_revision_id: current_revisions.select(:id))
      def current_accounts = FinancialSourceAccount.where(household_id: household.id, financial_extraction_revision_id: current_revisions.select(:id))
      def heads = SourceReviewHead.where(household_id: household.id, financial_source_event_id: current_events.select(:id))
      def drafts = SourceReviewDraft.where(household_id: household.id, source_review_head_id: heads.select(:id))
      def versions = SourceReviewVersion.where(household_id: household.id, source_review_head_id: heads.select(:id))
      def account_heads = SourceAccountReviewHead.where(household_id: household.id, financial_source_account_id: current_accounts.select(:id))
      def identities = SourceAccountIdentityVersion.where(household_id: household.id, source_account_review_head_id: account_heads.select(:id))
      def groups = SourceEconomicGroup.current_picture.where(household_id: household.id)
      def tracked_account(id) = SourceTrackedAccount.current_picture.where(household_id: household.id).find(id)
      def digest(value) = HouseholdFinance::Operations::PreparedOperation.fingerprint(value)

      def current_identity!(event, id)
        identity = identities.find(id)
        head = identity.source_account_review_head.reload
        unless head.financial_source_account_id == event.financial_source_account_id && head.approved_version_id == identity.id
          raise StaleReview, "Review this source account’s current identity before approving its rows."
        end
        identity
      end

      def lock_revisions!(ids)
        records = FinancialExtractionRevision.where(household_id: household.id, id: ids.uniq).order(:id).to_a
        raise ActiveRecord::RecordNotFound unless records.length == ids.uniq.length
        FinancialDocumentImport.where(household_id: household.id, id: records.filter_map(&:financial_document_import_id)).order(:id).lock.load
        records.each { |revision| HouseholdFinance::FinancialGenerationGuard.source!(revision.financial_document_import) }
        records.each(&:lock!)
      end

      private

      def revision_ids(action, input)
        case action.to_s
        when "account_link" then related_revision_ids(source_account(input[:source_account_id]).financial_source_events.pluck(:id))
        when "stage" then [ source_event(input[:event_id]).financial_extraction_revision_id ]
        when "approve", "cancel" then related_revision_ids([ drafts.find(input[:draft_id]).source_review_head.financial_source_event_id ])
        when "project" then [ versions.find(input[:version_id]).financial_source_event.financial_extraction_revision_id ]
        when "revision_approve" then [ input[:revision_id] ]
        when "economic_link"
          events = input[:members].map { |row| versions.find(row[:source_review_version_id]).financial_source_event.id }
          prior = input[:group_id] && groups.find(input[:group_id]).approved_version
          events += prior.source_economic_memberships.map { |member| member.source_review_version.financial_source_event.id } if prior
          related_revision_ids(events)
        end
      end

      def related_revision_ids(event_ids)
        current_ids = heads.where(financial_source_event_id: event_ids).pluck(:approved_version_id).compact
        aliases = versions.joins(:source_review_head).where(matched_version_id: current_ids).where("source_review_heads.approved_version_id = source_review_versions.id")
        linked = EconomicLinker.current_versions(household).select { |group| group.source_economic_memberships.any? { |member| current_ids.include?(member.source_review_version_id) } }
        affected_ids = event_ids + aliases.map { |version| version.financial_source_event.id } + linked.flat_map { |group| group.source_economic_memberships.map { |member| member.source_review_version.financial_source_event.id } }
        FinancialSourceEvent.where(household: household, id: affected_ids).pluck(:financial_extraction_revision_id).uniq
      end

      def link_account!(input)
        account = source_account(input[:source_account_id])
        head = account_heads.find_or_create_by!(financial_source_account: account)
        head.lock!
        check_base!(head, input)
        tracked = input[:tracked_account_id] ? tracked_account(input[:tracked_account_id]) : SourceTrackedAccount.create!(household: household, account_id: input[:account_id], label: input[:label], account_basis: input[:account_basis], approved_by_user: user)
        version = head.source_account_identity_versions.create!(household: household, source_tracked_account: tracked, statement_facts: input[:statement_facts],
          version_number: head.source_account_identity_versions.maximum(:version_number).to_i + 1, supersedes_id: head.approved_version_id, approved_by_user: user, reason: input[:reason], digest: digest(input))
        head.update!(approved_version: version)
        version
      end

      def stage!(input)
        event = source_event(input[:event_id])
        head = heads.find_or_create_by!(financial_source_event: event)
        head.lock!
        check_base!(head, input)
        current_identity!(event, input[:facts][:source_account_identity_version_id])
        pending = head.source_review_drafts.pending.first
        actual_pending = pending && { id: pending.id, lock_version: pending.lock_version, digest: pending.digest }
        unless actual_pending == input[:expected_pending_draft]
          raise StaleReview, "The pending proposal changed. Refresh before replacing it; nothing changed."
        end
        draft = pending || head.source_review_drafts.new(household: household)
        draft.lock! if draft.persisted?
        draft.update!(staged_by_user: user, base_version_id: head.approved_version_id, base_head_lock_version: head.lock_version,
          facts: input[:facts], projection: input[:projection], reason: input[:reason], digest: digest(input))
        draft
      end

      def approve!(input)
        draft = drafts.find(input[:draft_id])
        head = draft.source_review_head
        head.lock!
        draft.lock!
        check_draft!(draft, input)
        check_base!(head, base_version_id: draft.base_version_id, base_lock_version: draft.base_head_lock_version)
        event = head.financial_source_event
        facts = reviewed_facts(event, draft.facts)
        identity = current_identity!(event, facts[:source_account_identity_version_id])
        overlaps = OverlapDetector.new(household, event, facts).call
        validate_overlaps!(facts, overlaps)
        category = household.budget_categories.find(facts[:budget_category_id]) if facts[:budget_category_id]
        raise ArgumentError, "Choose an active category" if category && !category.active?
        attributes = facts.except(:source_account_identity_version_id).merge(source_account_identity_version: identity,
          category_snapshot: category ? { id: category.id, name: category.name, stack_key: category.stack_key } : { explicitly_uncategorized: true },
          source_artifact_digest: event.financial_extraction_revision.financial_document_import&.checksum_sha256,
          version_number: head.source_review_versions.maximum(:version_number).to_i + 1, supersedes_id: head.approved_version_id,
          approved_by_user: user, reason: draft.reason, digest: digest(facts: facts, projection: draft.projection, reason: draft.reason), projection: draft.projection)
        version = head.source_review_versions.create!(attributes.merge(household: household))
        ProjectionCorrector.new(self, version, draft.projection.deep_symbolize_keys).call
        head.update!(approved_version: version)
        draft.update!(status: "approved")
        if version.disposition != "include"
          household.transaction_drafts.pending.where(financial_source_event: event).order(:id).lock.each do |legacy|
            legacy.update!(status: "ignored", draft_payload: legacy.draft_payload.merge("source_review_version_id" => version.id, "source_review_disposition" => version.disposition))
          end
        end
        version
      end

      def cancel!(input)
        draft = drafts.find(input[:draft_id])
        draft.source_review_head.lock!
        draft.lock!
        check_draft!(draft, input)
        draft.update!(status: "cancelled")
        draft
      end

      def project!(input)
        version = versions.find(input[:version_id])
        version.source_review_head.lock!
        unless version.source_review_head.approved_version_id == version.id && version.digest == input[:expected_version_digest]
          raise StaleReview, "The approved expense version changed; nothing changed."
        end
        current_identity!(version.financial_source_event, version.source_account_identity_version_id)
        ProjectionCorrector.new(self, version, input[:projection]).call
      end

      def mark_review_pending!(revision)
        import = revision.financial_document_import
        return unless import && import.metadata["source_accounting_revision_id"].to_i == revision.id
        import.update!(metadata: import.metadata.merge("source_accounting_review_pending" => true))
      end

      def check_base!(head, input)
        unless head.approved_version_id == input[:base_version_id] && head.lock_version == input[:base_lock_version]
          raise StaleReview, "The approved source version changed. Refresh this review; nothing changed."
        end
      end

      def check_draft!(draft, input)
        unless draft.status == "pending" && draft.lock_version == input[:draft_lock_version] && draft.digest == input[:draft_digest]
          raise StaleReview, "The correction proposal changed. Refresh this review; nothing changed."
        end
      end

      def validate_overlaps!(facts, overlaps)
        if facts[:disposition] == "include"
          raise ArgumentError, "This physical source row or reviewed reference is already represented. Review a match or exclusion." if overlaps.any? { |row| row[:strength] == "strong" && row[:approved_version_id] }
          if overlaps.any? { |row| row[:strength] == "strong" } && facts[:overlap_disposition] != "canonical"
            raise ArgumentError, "Explicitly choose the canonical pending row; its other evidence must remain pending for matching or exclusion."
          end
          if overlaps.any? { |row| row[:strength] == "ambiguous" } && facts[:overlap_disposition] != "distinct"
            raise ArgumentError, "These rows may overlap. Explicitly confirm they are distinct or match an approved row."
          end
        elsif facts[:disposition] == "match"
          target = versions.find(facts[:matched_version_id])
          raise StaleReview, "The matched source version changed" unless target.source_review_head.reload.approved_version_id == target.id && target.disposition == "include"
          current_identity!(target.financial_source_event, target.source_account_identity_version_id)
          own = identities.find(facts[:source_account_identity_version_id]).source_tracked_account_id
          unless target.source_tracked_account.id == own && target.signed_amount_cents == facts[:signed_amount_cents] && target.posted_on&.iso8601 == facts[:posted_on] && target.event_type == facts[:event_type] && target.purchase_amount_cents == facts[:purchase_amount_cents]
            raise ArgumentError, "A duplicate match must have the same reviewed account, amount, posted date and classification."
          end
        end
      end

      def reviewed_facts(event, raw)
        input = raw.to_h.deep_symbolize_keys
        disposition = input.fetch(:disposition).to_s
        raise ArgumentError, "Choose include, match, exclude or informational" unless disposition.in?(%w[include match exclude informational])
        identity = current_identity!(event, input.fetch(:source_account_identity_version_id))
        type = input.fetch(:event_type).to_s
        raise ArgumentError, "Unsupported event classification" unless type.in?(FinancialSourceEvent::TYPES)
        amount = input[:signed_amount_cents].nil? ? nil : cents!(input[:signed_amount_cents])
        posted = input[:posted_on].nil? ? nil : date!(input[:posted_on])
        authorized = input[:authorized_on].nil? ? nil : date!(input[:authorized_on])
        merchant = text(input[:merchant], 120)
        category = input[:budget_category_id] && household.budget_categories.find(input[:budget_category_id])
        purchase = input[:purchase_amount_cents].nil? ? nil : cents!(input[:purchase_amount_cents], positive: true)
        if disposition.in?(%w[include match])
          raise ArgumentError, "Resolve the amount, posted date and classification before approval" unless amount && !amount.zero? && posted && type != "unknown"
          raise ArgumentError, "A posted source date cannot be in the future" if Date.iso8601(posted) > Date.current
          period = identity.statement_facts
          if period["period_start_on"] && period["period_end_on"] && !posted.between?(period["period_start_on"], period["period_end_on"])
            raise ArgumentError, "The posted date is outside the reviewed account statement period"
          end
          raise ArgumentError, "Purchases and fees must be outflows" if type.in?(%w[purchase fee]) && !amount.negative?
          raise ArgumentError, "Refunds and income must be inflows" if type.in?(%w[refund income]) && !amount.positive?
          if amount.negative? && type.in?(%w[purchase fee interest])
            merchant = required_text(input[:merchant], 120)
            raise ArgumentError, "Explicitly review the category, including uncategorized" unless input.key?(:budget_category_id)
            purchase ||= amount.abs unless type == "purchase"
            raise ArgumentError, "Review the complete economic purchase amount" unless purchase && purchase >= amount.abs
          elsif purchase
            raise ArgumentError, "Income, refunds and movements cannot have a purchase amount"
          end
        elsif disposition == "informational"
          raise ArgumentError, "Informational rows have no posted account movement" if amount || purchase
        end
        match = disposition == "match" ? versions.find(input.fetch(:matched_version_id)).id : nil
        overlap = input.fetch(:overlap_disposition).to_s
        raise ArgumentError, "Choose a reviewed overlap disposition" unless overlap.in?(%w[new distinct canonical match excluded])
        { source_account_identity_version_id: identity.id, disposition: disposition, event_type: type, signed_amount_cents: amount,
          posted_on: posted, authorized_on: authorized, merchant: merchant, purchase_amount_cents: purchase, budget_category_id: category&.id,
          matched_version_id: match, external_reference: text(input[:external_reference], 160), overlap_disposition: overlap }
      end

      def statement_facts(raw)
        facts = raw.to_h.deep_symbolize_keys
        result = %i[period_start_on period_end_on].index_with { |key| facts[key].nil? ? nil : date!(facts[key]) }
        %i[opening_balance_cents closing_balance_cents printed_debit_cents printed_credit_cents].each { |key| result[key] = facts[key].nil? ? nil : cents!(facts[key]) }
        result[:printed_row_count] = facts[:printed_row_count].nil? ? nil : integer(facts[:printed_row_count])
        result[:printed_row_count_basis] = facts.fetch(:printed_row_count_basis, "posted").to_s
        raise ArgumentError, "Choose posted or all rows for the printed census" unless result[:printed_row_count_basis].in?(%w[posted all])
        raise ArgumentError, "Printed totals cannot be negative" if %i[printed_debit_cents printed_credit_cents].any? { |key| result[key].to_i.negative? }
        raise ArgumentError, "Statement period is reversed" if result[:period_start_on] && result[:period_end_on] && result[:period_start_on] > result[:period_end_on]
        result
      end

      def coverage_date(value, identity, field, status)
        return date!(value) unless status == "qualified" && value.nil?

        unless identity.source_account_review_head.approved_version_id == identity.id && identity.statement_facts[field].nil?
          raise ArgumentError, "A known or changed statement period cannot be omitted; review the current account details"
        end
        nil
      end

      def projection(raw)
        input = raw.to_h.deep_symbolize_keys
        action = input.fetch(:action).to_s
        raise ArgumentError, "Unsupported financial projection action" unless action.in?(%w[none create replace void])
        raise ArgumentError, "Only replace or void may name an existing transaction" if !action.in?(%w[replace void]) && (input[:transaction_id] || input[:expected_digest])
        transaction = household.household_transactions.find(input[:transaction_id]) if input[:transaction_id]
        raise ArgumentError, "Identify the approved transaction and its reviewed fingerprint" if action.in?(%w[replace void]) && (!transaction || input[:expected_digest].blank?)
        { action: action, transaction_id: transaction&.id, expected_digest: input[:expected_digest].presence }
      end

      def event_snapshot(event, facts, projection)
        head = heads.find_by(financial_source_event: event)
        identity = account_heads.find_by(financial_source_account_id: event.financial_source_account_id)
        { event_id: event.id, source_revision_digest: event.financial_extraction_revision.payload_digest, head: head_state(head),
          pending: head&.source_review_drafts&.pending&.map { |draft| draft_state(draft) }, account: head_state(identity),
          overlaps: OverlapDetector.new(household, event, facts).call,
          projection_digest: projection[:transaction_id] && ProjectionCorrector.snapshot_digest(household.household_transactions.find(projection[:transaction_id])) }
      end

      def head_state(head) = { id: head&.id, approved_version_id: head&.approved_version_id, lock_version: head&.lock_version || 0 }
      def draft_state(draft) = { id: draft.id, lock_version: draft.lock_version, digest: draft.digest, status: draft.status }
      def version_state(version) = { id: version.id, digest: version.digest, current_id: version.source_review_head.reload.approved_version_id }
      def nullable_id(value) = value.nil? ? nil : integer(value, positive: true)

      def integer(value, positive: false)
        raise ArgumentError, "Expected an exact integer" unless value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)
        result = value.to_i
        raise ArgumentError, "Integer is outside the supported range" if positive ? result <= 0 : result < 0
        result
      end

      def cents!(value, positive: false)
        raise ArgumentError, "Use exact integer cents" unless value.is_a?(Integer) || value.is_a?(String) && value.match?(/\A-?\d+\z/)
        result = value.to_i
        raise ArgumentError, "Amount is outside the supported range" if result.abs > AccountingContract::CENT_LIMIT || positive && result <= 0
        result
      end

      def date!(value)
        raise ArgumentError, "Use an exact YYYY-MM-DD date" unless value.to_s.match?(/\A\d{4}-\d{2}-\d{2}\z/)
        Date.iso8601(value.to_s).iso8601
      rescue Date::Error
        raise ArgumentError, "Source date is invalid"
      end

      def text(value, length)
        value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish.presence&.truncate(length)
      end

      def required_text(value, length)
        text(value, length) || raise(ArgumentError, "A reviewed label or reason is required")
      end
    end
  end
end
