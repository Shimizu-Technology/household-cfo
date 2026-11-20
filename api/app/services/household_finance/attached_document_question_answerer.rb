# frozen_string_literal: true

module HouseholdFinance
  class AttachedDocumentQuestionAnswerer
    MAX_IMPORTS = 5
    MAX_TRANSACTION_ROWS = MAX_IMPORTS * DocumentTransactionDraftPersister::MAX_DRAFTS
    MAX_SETUP_ROWS = MAX_IMPORTS * FinancialDocuments::Extractor::MAX_ITEMS
    MAX_PENDING_PLAN_FIT_DRAFTS = MAX_TRANSACTION_ROWS
    MAX_LISTED_ROWS = 8
    MONTH_NUMBERS = Date::ABBR_MONTHNAMES.each_with_index.filter_map { |name, index| [ name.downcase, index ] if name }.to_h
      .merge(Date::MONTHNAMES.each_with_index.filter_map { |name, index| [ name.downcase, index ] if name }.to_h).freeze
    MONTH_PATTERN = /(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|jun(?:e)?|jul(?:y)?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)/i
    GENERIC_REVIEW_PATTERN = /\A(?:please\s+)?(?:review|read|check|process|summarize)\b/i
    SUBSTANTIVE_QUESTION_PATTERN = /\b(?:total|sum|add up|how much|largest|biggest|highest|which|what|merchant|where|category|when|date|period|fit|fits|within|covered|room|duplicate|double charged|charged twice|over\s+\$|under\s+\$)\b/i
    # "voucher $150 plus debit $34.88": how she paid for the receipt, not a question about its rows.
    PAYMENT_DESCRIPTION = /\b(?:vouchers?|gift\s*-?\s*cards?|gift\s+certificates?|store\s+credit|rewards?|loyalty|points|debit|credit\s+card|cash|paid\s+(?:with|by|using))\b/i
    SETUP_REQUEST_PATTERN = /\A(?:(?:can|could|would)\s+you\s+)?(?:use|set up|import).{0,100}\b(?:budget|profile|household|income)\b/i

    # "Review and show transactions" or "Review and tell me the amount I paid" opens
    # like a plain review but asks a question this class answers from the rows.
    def self.read_acknowledgement_request?(message)
      generic_review_request?(message) && !new(nil, message: message, document_imports: []).answerable_transaction_question?
    end

    def self.generic_review_request?(message)
      normalized = message.to_s.squish
      (normalized.match?(GENERIC_REVIEW_PATTERN) && !normalized.match?(SUBSTANTIVE_QUESTION_PATTERN)) || normalized.match?(SETUP_REQUEST_PATTERN)
    end

    def initialize(household, message:, document_imports:, max_transaction_rows: MAX_TRANSACTION_ROWS, max_setup_rows: MAX_SETUP_ROWS, max_pending_plan_fit_drafts: MAX_PENDING_PLAN_FIT_DRAFTS)
      @household = household
      @message = message.to_s.squish
      @document_imports = Array(document_imports).first(MAX_IMPORTS)
      @max_transaction_rows = max_transaction_rows
      @max_setup_rows = max_setup_rows
      @max_pending_plan_fit_drafts = max_pending_plan_fit_drafts
    end

    def call
      return unless document_imports.any?
      return unless document_imports.all? { |document_import| document_import.household_id == household.id }
      return evidence_bound_answer if evidence_exceeds_complete_bound?

      if self.class.read_acknowledgement_request?(message)
        read_reply = UploadReadReply.call(household, document_imports)
        return read_reply if read_reply
      end
      rows = transaction_rows
      setup = setup_rows
      return UploadReadReply.call(household, document_imports) || no_evidence_answer if rows.empty? && setup.empty?

      # Only past the date and risk checks: "Is this fraudulent? I paid with debit" is never a receipt reply.
      receipt_reply = receipt_draft_reply(rows) unless invalid_date_scope? || unsupported_risk_or_advice_question?
      return receipt_reply if receipt_reply

      parts = direct_answer_parts(rows, setup)
      if parts.empty?
        read_reply = UploadReadReply.call(household, document_imports)
        return (message.include?("?") ? "#{read_reply} I can’t tell anything more from this file." : read_reply) if read_reply
        parts << unsupported_question_answer
      end
      parts << failed_import_notice
      parts << review_boundary(rows, setup)
      parts.compact.join(" ")
    end

    def answerable_transaction_question?
      transaction_question?
    end

    def answerable_question?
      transaction_question? || setup_question?
    end

    private

    attr_reader :household, :message, :document_imports, :max_transaction_rows, :max_setup_rows, :max_pending_plan_fit_drafts

    # One receipt she just sent: talk about its draft when she only says how she paid, or names a store
    # the receipt doesn't, never "no attached row matching" a store she named in her own words.
    def receipt_draft_reply(rows)
      return unless evidence_imports.any? && evidence_imports.all? { |document_import| document_import.document_kind == "receipt" }
      return unless rows.one? && rows.first.fetch(:status) == "pending"
      unmatched = transaction_question? && explicit_transaction_scope?(rows) && scoped_transaction_rows(rows).empty?
      return unless payment_only? || unmatched

      ReceiptDraftReply.call(rows.first.fetch(:record), message: message)
    end

    # "voucher $150 plus debit $34.88": only how she paid. A question beside it ("Does this fit in my
    # Groceries budget?", "What category is this?") is answered as that question.
    def payment_only?
      return false unless message.match?(PAYMENT_DESCRIPTION)
      # "I paid with debit" says how, not "how much did I pay".
      return false if self.class.new(household, message: message.gsub(/\bpaid\b/i, " "), document_imports: []).answerable_question?

      message.scan(/[^.?!]*\?/).all? { |question| question.match?(PAYMENT_DESCRIPTION) }
    end

    def transaction_rows
      @transaction_rows ||= TransactionDraft
        .where(financial_document_import_id: evidence_imports.map(&:id), household_id: household.id)
        .where.not(status: "ignored")
        .includes(:budget_category, transaction_draft_splits: :budget_category)
        .order(:occurred_on, :id)
        .limit(max_transaction_rows)
        .map do |draft|
          category_allocations = category_allocations_for(draft)
          {
            record: draft,
            merchant: draft.merchant,
            amount_cents: draft.total_amount_cents,
            occurred_on: draft.occurred_on,
            category_allocations: category_allocations,
            category: category_allocations.keys.to_sentence,
            status: draft.status
          }
        end
    end

    def setup_rows
      @setup_rows ||= FinancialDocumentImportItem
        .where(financial_document_import_id: evidence_imports.map(&:id), ignored: false)
        .order(:id)
        .limit(max_setup_rows)
        .map do |item|
          {
            target_type: item.target_type,
            label: item.label,
            amount_cents: item.amount_cents,
            balance_cents: item.balance_cents,
            payment_cents: item.payment_cents,
            cadence: item.cadence,
            interest_rate_percent: item.interest_rate_percent,
            state: item.applied? ? "applied" : "pending review"
          }
        end
    end

    def evidence_imports
      @evidence_imports ||= document_imports.reject { |document_import| document_import.status.in?(%w[uploaded processing failed]) }
    end

    def category_allocations_for(draft)
      splits = draft.transaction_draft_splits.to_a
      if splits.any?
        return splits.each_with_object(Hash.new(0)) do |split, allocations|
          label = split.budget_category&.name || split.category_name.presence || "Uncategorized"
          allocations[label] += split.amount_cents
        end
      end

      { (draft.budget_category&.name || "Uncategorized") => draft.total_amount_cents }
    end

    def direct_answer_parts(rows, setup)
      if invalid_date_scope?
        return [ "I could not apply that date or date range because it is not a valid calendar date. Use a valid date and try again." ]
      end
      return [ unsupported_question_answer ] if unsupported_risk_or_advice_question?

      parts = []
      if transaction_question? && explicit_transaction_scope?(rows) && scoped_transaction_rows(rows).empty?
        parts << "I found no attached transaction row matching the named merchant or category."
        return parts
      end
      parts << transaction_total_answer(rows) if transaction_total_question? && rows.any?
      parts << monthly_total_answer(rows) if transaction_total_question? && multiple_months_requested?
      parts << duplicate_charge_answer(rows) if duplicate_question? && rows.any?
      parts << plan_fit_answer(rows) if plan_fit_question? && rows.any?
      parts << largest_transaction_answer(rows) if largest_question? && rows.any?
      parts << transaction_list_answer(rows) if transaction_list_question? && rows.any?
      parts << category_answer(rows) if category_question? && rows.any?
      parts << date_answer(rows) if date_question? && rows.any?
      parts << setup_answer(setup) if setup_question? && setup.any?
      parts.compact.uniq
    end

    def transaction_total_answer(rows)
      scoped = scoped_transaction_rows(rows)
      matching = filtered_transaction_rows(scoped)
      qualifier = explicit_transaction_scope?(rows) || date_scope_requested? || threshold_requested? ? " matching that merchant, category, date, or amount filter" : ""
      "The files you sent have #{matching.length} transaction row#{'s' unless matching.one?}#{qualifier} totaling #{money(matching.sum { |row| question_amount_cents(row) })}."
    end

    def largest_transaction_answer(rows)
      row = filtered_transaction_rows(scoped_transaction_rows(rows)).max_by { |candidate| question_amount_cents(candidate) }
      return "I found no attached transaction row matching those filters." unless row

      "The largest attached transaction is #{row.fetch(:merchant)} for #{scoped_amount_description(row)} on #{formatted_date(row.fetch(:occurred_on))}, categorized as #{row.fetch(:category)}."
    end

    def transaction_list_answer(rows)
      matching = filtered_transaction_rows(scoped_transaction_rows(rows))
      return "I found no attached transaction row matching those filters." if matching.empty?

      listed = matching.first(MAX_LISTED_ROWS).map do |row|
        "#{row.fetch(:merchant)} — #{scoped_amount_description(row)} on #{formatted_date(row.fetch(:occurred_on))} (#{row.fetch(:category)}, #{status_label(row.fetch(:status))})"
      end
      suffix = matching.length > listed.length ? "; plus #{matching.length - listed.length} more attached row#{'s' unless matching.length - listed.length == 1}" : ""
      "Attached transactions: #{listed.join('; ')}#{suffix}."
    end

    def category_answer(rows)
      totals = filtered_transaction_rows(scoped_transaction_rows(rows)).each_with_object(Hash.new(0)) do |row, result|
        category_allocations_for_question(row).each { |category, amount| result[category] += amount }
      end.sort_by { |(_category, amount)| -amount }
      return if totals.empty?

      listed = totals.first(MAX_LISTED_ROWS).map { |category, amount| "#{category}: #{money(amount)}" }
      "Attached transaction totals by category are #{listed.to_sentence}."
    end

    def date_answer(rows)
      dates = filtered_transaction_rows(scoped_transaction_rows(rows)).filter_map { |row| row.fetch(:occurred_on) }
      return if dates.empty?

      range = dates.min == dates.max ? formatted_date(dates.min) : "#{formatted_date(dates.min)} through #{formatted_date(dates.max)}"
      "The attached transaction dates cover #{range}."
    end

    def duplicate_charge_answer(rows)
      matching = filtered_transaction_rows(scoped_transaction_rows(rows))
      duplicates = matching.group_by do |row|
        [ normalized_entity(row.fetch(:merchant)), row.fetch(:amount_cents), row.fetch(:occurred_on) ]
      end.values.select { |group| group.many? }
      if duplicates.empty?
        return "I found no exact duplicate charges in the files you sent. I compared merchant, amount, and date; similar charges with different details still need manual review."
      end

      listed = duplicates.first(MAX_LISTED_ROWS).map do |group|
        row = group.first
        "#{row.fetch(:merchant)} — #{money(row.fetch(:amount_cents))} on #{formatted_date(row.fetch(:occurred_on))} appears #{group.length} times"
      end
      suffix = duplicates.length > listed.length ? "; plus #{duplicates.length - listed.length} more exact-match group#{'s' unless duplicates.length - listed.length == 1}" : ""
      "I found #{duplicates.length} potential duplicate charge group#{'s' unless duplicates.one?} in the files you sent: #{listed.join('; ')}#{suffix}. These are exact merchant, amount, and date matches for you to review; nothing was changed."
    end

    def setup_answer(setup)
      relevant = setup.select { |row| setup_type_matches_question?(row.fetch(:target_type)) }
      relevant = setup if relevant.empty?
      listed = relevant.first(MAX_LISTED_ROWS).map { |row| setup_row_label(row) }
      suffix = relevant.length > listed.length ? "; plus #{relevant.length - listed.length} more value#{'s' unless relevant.length - listed.length == 1}" : ""
      "The files you sent show #{listed.join('; ')}#{suffix}."
    end

    def unsupported_question_answer
      "I can’t answer that question from this file. Check the review card before deciding what to approve; I won’t guess."
    end

    def review_boundary(rows, setup)
      pending_transactions = rows.count { |row| row.fetch(:status) == "pending" }
      confirmed_transactions = rows.length - pending_transactions
      pending_setup = setup.count { |row| row.fetch(:state) == "pending review" }
      source = document_imports.length > 1 ? "these files" : "this file"
      parts = []
      if pending_transactions.positive?
        parts << "#{pending_transactions} #{pending_transactions == 1 ? 'purchase' : 'purchases'} from #{source} #{pending_transactions == 1 ? 'is' : 'are'} still waiting for you to approve; #{pending_transactions == 1 ? "it doesn't" : "they don't"} count in your spending until you do."
      end
      if pending_setup.positive?
        parts << "#{pending_setup} other #{pending_setup == 1 ? 'value' : 'values'} from #{source}, like income, bills or debts, #{pending_setup == 1 ? 'is' : 'are'} also waiting for your approval before #{pending_setup == 1 ? 'it changes' : 'they change'} your plan."
      end
      if confirmed_transactions.positive? && parts.any?
        parts << (confirmed_transactions == 1 ? "One purchase from it is already approved." : "#{confirmed_transactions} purchases from it are already approved.")
      end
      parts << "Nothing from #{source} is waiting for your approval, and nothing from this message was saved or changed." if parts.empty?
      parts.join(" ")
    end

    def failed_import_notice
      UploadFailureReply.for_files(document_imports)
    end

    def no_evidence_answer
      failure = failed_import_notice
      read = document_imports.any? { |document| !document.failed? }
      parts = []
      parts << "I read #{document_imports.one? ? 'this file' : document_imports.any?(&:failed?) ? 'the other files' : 'these files'}, but couldn’t find the money details needed to answer that question. Nothing changed." if read
      parts << failure
      parts.compact.join(" ")
    end

    def transaction_total_question?
      message.match?(/\b(?:total|sum|add up|how much|amount|spend|spending|spent|paid)\b/i) || message.match?(/\b(?:over|above|more than|greater than|under|below|less than)\s+\$/i)
    end

    def transaction_question?
      transaction_total_question? || duplicate_question? || plan_fit_question? || largest_question? || transaction_list_question? || category_question? || date_question?
    end

    def duplicate_question?
      message.match?(/\b(?:duplicates?|duplicated|double[ -]?charged?|charged twice|same charge|repeated (?:charges?|transactions?))\b/i)
    end

    def unsupported_risk_or_advice_question?
      message.match?(/\b(?:fraud|fraudulent|dispute|chargeback|unauthori[sz]ed|scam|suspicious|stolen|legitimate|legit|trustworthy|trust)\b/i) ||
        message.match?(/\b(?:what|which).{0,60}\bshould\b/i)
    end

    def plan_fit_question?
      message.match?(/\b(?:fit|fits|within|covered by|room in)\b.{0,60}\b(?:plan|budget)\b|\b(?:plan|budget)\b.{0,60}\b(?:fit|fits|within|cover|room)\b/i)
    end

    def largest_question?
      message.match?(/\b(?:largest|biggest|highest|most expensive)\b/i)
    end

    def transaction_list_question?
      return false if duplicate_question? && !message.match?(/\b(?:which|what|list|show)\b/i)

      message.match?(
        /\b(?:list|show)\b.{0,40}\b(?:transactions?|purchases?|charges?|merchants?)\b|\b(?:which|what)\s+(?:transactions?|purchases?|charges?|merchants?)\b|\bwhich\s+merchant\b|\bwhere\s+(?:did|was|were|are)\b/i
      ) && !setup_question?
    end

    def category_question?
      message.match?(/\b(?:category|categories|categorized|type of spending)\b/i)
    end

    def date_question?
      message.match?(/\b(?:when|date|dates|period|range|month)\b/i)
    end

    def setup_question?
      message.match?(/\b(?:income|paycheck|pay stub|salary|expense|budget|profile|account|balance|debt|payment|goal|setup|set up)\b/i)
    end

    def setup_type_matches_question?(type)
      patterns = {
        "income_source" => /\b(?:income|paycheck|pay stub|salary)\b/i,
        "expense_item" => /\b(?:expense|budget|spend)\b/i,
        "account" => /\b(?:account|balance|asset)\b/i,
        "debt" => /\b(?:debt|loan|card|payment|balance)\b/i,
        "goal" => /\bgoal\b/i,
        "profile_note" => /\b(?:profile|note)\b/i
      }
      message.match?(patterns.fetch(type, /\A\b\B/))
    end

    def threshold_filtered(rows)
      amount = message[/\$\s*([\d,]+(?:\.\d{1,2})?#{Money::CHAT_THOUSANDS_SOURCE}?)/, 1]
      return rows unless amount

      cents = Money.chat_cents(amount)
      if message.match?(/\b(?:over|above|more than|greater than)\b/i)
        rows.select { |row| question_amount_cents(row) > cents }
      elsif message.match?(/\b(?:under|below|less than)\b/i)
        rows.select { |row| question_amount_cents(row) < cents }
      else
        rows
      end
    end

    def filtered_transaction_rows(rows)
      threshold_filtered(date_filtered(rows))
    end

    def threshold_requested?
      message.match?(/\b(?:over|above|more than|greater than|under|below|less than)\b/i) && message.match?(/\$\s*[\d,]+/)
    end

    def scoped_transaction_rows(rows)
      matches = matching_transaction_entities(rows)
      return rows unless matches.any? || unmatched_transaction_scope_requested?
      return [] if matches.empty?

      merchant_matches = matches.select { |match| match.fetch(:field) == :merchant }
      category_matches = matches.select { |match| match.fetch(:field) == :category }
      rows.select do |row|
        merchant_match = merchant_matches.empty? || merchant_matches.any? { |match| merchant_entities(row).include?(match.fetch(:value)) }
        category_match = category_matches.empty? || category_matches.any? do |match|
          row.fetch(:category_allocations).keys.any? { |category| entity_matches?(category, match.fetch(:value)) }
        end
        merchant_match && category_match
      end
    end

    def explicit_transaction_scope?(rows)
      matching_transaction_entities(rows).any? || unmatched_transaction_scope_requested?
    end

    def matching_transaction_entities(rows)
      @matching_transaction_entities ||= begin
        normalized = " #{normalized_entity(message)} "
        rows.flat_map do |row|
          # "the Ross receipt" names the store the way she reads it, not "ROSS DRESS FOR LESS #123".
          values = merchant_entities(row).map { |value| { field: :merchant, value: value } }
          values.concat(row.fetch(:category_allocations).keys.map { |category| { field: :category, value: normalized_entity(category) } })
          values.filter_map do |entry|
            value = entry.fetch(:value)
            next if value.blank? || !entity_mentioned?(normalized, value)

            entry
          end
        end.uniq
      end
    end

    def merchant_entities(row)
      [ row.fetch(:merchant), SpendingPatterns::MerchantName.call(row.fetch(:merchant)) ].map { |value| normalized_entity(value) }.compact_blank.uniq
    end

    def entity_mentioned?(normalized_message, normalized_value)
      variants = [ normalized_value, normalized_value.singularize, normalized_value.pluralize ].uniq
      variants.any? { |variant| normalized_message.include?(" #{variant} ") }
    end

    def entity_matches?(value, normalized_match)
      normalized = normalized_entity(value)
      [ normalized, normalized.singularize, normalized.pluralize ].include?(normalized_match) ||
        [ normalized_match, normalized_match.singularize, normalized_match.pluralize ].include?(normalized)
    end

    def unmatched_transaction_scope_requested?
      @unmatched_transaction_scope_requested ||= begin
        candidate = message.match(/\b(?:at|from)\s+([^?.,;]{2,60})/i)&.[](1) ||
          message.match(/\bsp(?:end|ent|ending)\s+on\s+([^?.,;]{2,60})/i)&.[](1) ||
          message.match(/\b(?:in|under)\s+(?:the\s+)?([^?.,;]{2,60}?)\s+categor(?:y|ies)\b/i)&.[](1) ||
          message.match(/\bcategory\s+(?:named|called)\s+["']?([^?.,;"']{2,60})/i)&.[](1)
        candidate.present? && !generic_attachment_reference?(candidate) && !date_like_scope?(candidate)
      end
    end

    def date_like_scope?(candidate)
      candidate.to_s.match?(/\A\s*(?:#{MONTH_PATTERN}|today|yesterday|this month|last month|next month|(?:19|20)\d{2}(?:-\d{1,2}-\d{1,2})?|\d{1,2}[\/-]\d{1,2})\b/i)
    end

    def generic_attachment_reference?(candidate)
      normalized_entity(candidate).match?(/\A(?:this|these|the|my|attached)?\s*(?:upload|uploads|file|files|document|documents|receipt|receipts|statement|statements|attachment|attachments)\z/)
    end

    def normalized_entity(value)
      value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^a-z0-9]+/, " ").squish
    end

    def matched_category_values
      matching_transaction_entities(transaction_rows).select { |match| match.fetch(:field) == :category }.map { |match| match.fetch(:value) }.uniq
    end

    def category_allocations_for_question(row)
      matches = matched_category_values
      return row.fetch(:category_allocations) if matches.empty?

      row.fetch(:category_allocations).select do |category, _amount|
        matches.any? { |match| entity_matches?(category, match) }
      end
    end

    def question_amount_cents(row)
      return row.fetch(:amount_cents) if matched_category_values.empty?

      category_allocations_for_question(row).values.sum
    end

    def scoped_amount_description(row)
      scoped = question_amount_cents(row)
      return money(scoped) if matched_category_values.empty? || scoped == row.fetch(:amount_cents)

      "#{money(scoped)} in #{category_allocations_for_question(row).keys.to_sentence} of #{money(row.fetch(:amount_cents))} total"
    end

    def plan_fit_answer(rows)
      scoped = filtered_transaction_rows(scoped_transaction_rows(rows))
      return "I found no attached transaction row matching those merchant, category, date, or amount filters, so I cannot compare it with the plan." if scoped.empty?

      pending = scoped.select { |row| row.fetch(:status) == "pending" }
      if pending.empty?
        return "The matching attached transaction row#{'s are' if scoped.many?}#{' is' if scoped.one?} already resolved. I did not add #{scoped.one? ? 'it' : 'them'} to the plan again as pending spending."
      end
      return "I can verify the attached amount, but I cannot tell whether it fits the plan because the transaction date is missing." if pending.any? { |row| row.fetch(:occurred_on).blank? }

      impacts = pending.flat_map do |row|
        plan = read_only_plan_for(row.fetch(:occurred_on)&.year)
        return unavailable_plan_fit_answer(pending) unless plan&.fetch(:plan_available, false)
        plan = plan_with_complete_pending_drafts(plan, row.fetch(:occurred_on))
        return incomplete_pending_plan_fit_answer unless plan

        TransactionDraftBudgetImpact.new(annual_plan: plan, draft: row.fetch(:record)).call.map do |impact|
          impact.merge(occurred_on: row.fetch(:occurred_on))
        end
      end
      return "I can verify the attached amount, but I cannot tell whether it fits the plan because its category is not matched to an approved plan category." if impacts.empty? || impacts.any? { |impact| impact.fetch(:status) == "needs_category" }

      periods = impacts.map { |impact| impact.fetch(:occurred_on).beginning_of_month }.uniq
      categories = impacts.group_by { |impact| [ impact.fetch(:category_name), impact.fetch(:occurred_on).beginning_of_month ] }.map do |(category, period), category_impacts|
        representative = category_impacts.min_by { |impact| impact.fetch(:remaining_if_approved_cents) }
        label = periods.many? ? "#{category} in #{period.strftime('%b %Y')}" : category
        if representative.fetch(:status) == "over"
          "#{label} would be #{money(representative.fetch(:remaining_if_approved_cents).abs)} over plan"
        else
          "#{label} would remain within plan with #{money(representative.fetch(:remaining_if_approved_cents))} left"
        end
      end
      resolved_note = scoped.length > pending.length ? " I excluded #{scoped.length - pending.length} resolved attached row#{'s' unless scoped.length - pending.length == 1} from the hypothetical so it would not be counted twice." : ""
      "If you approve the attached pending transaction#{'s' if pending.many?}, #{categories.to_sentence}. This comparison uses the approved plan, confirmed actuals, and other pending drafts for the transaction month.#{resolved_note}"
    end

    def read_only_plan_for(year)
      return unless year && AnnualBudgetManager.supported_year?(year)

      @read_only_plans ||= {}
      @read_only_plans[year] ||= AnnualBudgetManager.new(household, year: year).read_only_plan_data.deep_symbolize_keys
    end

    def unavailable_plan_fit_answer(rows)
      amount = rows.sum { |row| question_amount_cents(row) }
      "I can verify #{money(amount)} in the files you sent, waiting for your approval, but there is no confirmed annual plan for that transaction year, so I cannot safely say whether it fits."
    end

    def plan_with_complete_pending_drafts(plan, date)
      period = date.beginning_of_month
      @complete_pending_plan_by_period ||= {}
      return @complete_pending_plan_by_period[period] if @complete_pending_plan_by_period.key?(period)

      scope = household.transaction_drafts.pending.excluding_non_spending_plaid.where(occurred_on: period..period.end_of_month)
      if scope.limit(max_pending_plan_fit_drafts + 1).count > max_pending_plan_fit_drafts
        return @complete_pending_plan_by_period[period] = nil
      end

      complete_pending = scope
        .includes(:budget_category, transaction_draft_splits: :budget_category)
        .order(:id)
        .to_a
      @complete_pending_plan_by_period[period] = plan.merge(pending_transaction_drafts: complete_pending)
    end

    def incomplete_pending_plan_fit_answer
      "I can verify the attached amount, but I cannot safely compare it with the plan because that month has more than #{max_pending_plan_fit_drafts} pending transaction drafts. Review or resolve a smaller batch first; I did not calculate a partial plan result."
    end

    def evidence_exceeds_complete_bound?
      evidence_transaction_scope.limit(max_transaction_rows + 1).count > max_transaction_rows ||
        evidence_setup_scope.limit(max_setup_rows + 1).count > max_setup_rows
    end

    def evidence_transaction_scope
      TransactionDraft.current_picture.where(financial_document_import_id: evidence_imports.map(&:id), household_id: household.id).where.not(status: "ignored")
    end

    def evidence_setup_scope
      FinancialDocumentImportItem.where(financial_document_import_id: evidence_imports.map(&:id), ignored: false)
    end

    def evidence_bound_answer
      "These files contain more lines than I can check completely in one answer. Review the files separately or send a smaller batch; I did not calculate a partial total, and no household numbers changed."
    end

    def date_filtered(rows)
      scope = date_scope
      return rows unless scope

      rows.select do |row|
        date = row.fetch(:occurred_on)
        next false unless date

        case scope.fetch(:type)
        when :exact
          date == scope.fetch(:date)
        when :month_day_exact
          date.month == scope.fetch(:month) && date.day == scope.fetch(:day) && (!scope[:year] || date.year == scope.fetch(:year))
        when :exact_range
          date >= scope.fetch(:start) && date <= scope.fetch(:finish)
        when :month_day_range
          value = [ date.month, date.day ]
          start_value = scope.fetch(:start)
          finish_value = scope.fetch(:finish)
          within_range = if (start_value <=> finish_value) <= 0
            (value <=> start_value) >= 0 && (value <=> finish_value) <= 0
          else
            (value <=> start_value) >= 0 || (value <=> finish_value) <= 0
          end
          within_range && (!scope[:year] || date.year == scope.fetch(:year))
        when :months
          scope.fetch(:months).include?(date.month) && (!scope[:year] || date.year == scope.fetch(:year))
        when :year
          date.year == scope.fetch(:year)
        end
      end
    end

    def date_scope_requested?
      date_scope.present?
    end

    def multiple_months_requested?
      scope = date_scope
      return false unless scope

      (scope[:type] == :months && scope.fetch(:months).many?) ||
        (scope[:type] == :month_day_range && scope.fetch(:start).first != scope.fetch(:finish).first) ||
        (scope[:type] == :exact_range && scope.fetch(:start).month != scope.fetch(:finish).month)
    end

    def monthly_total_answer(rows)
      matching = filtered_transaction_rows(scoped_transaction_rows(rows))
      totals = matching.group_by { |row| row.fetch(:occurred_on).beginning_of_month }.sort.map do |month, month_rows|
        "#{month.strftime('%b %Y')}: #{money(month_rows.sum { |row| question_amount_cents(row) })}"
      end
      return if totals.empty?

      "By month, the matching lines in the files you sent total #{totals.to_sentence}."
    end

    def date_scope
      return @date_scope if defined?(@date_scope)

      @invalid_date_scope = false
      return @date_scope = { type: :exact, date: Date.current } if message.match?(/\btoday\b/i)
      return @date_scope = { type: :exact, date: Date.current.yesterday } if message.match?(/\byesterday\b/i)

      relative_month = if message.match?(/\b(?:this|current) month\b/i)
        Date.current
      elsif message.match?(/\blast month\b/i)
        Date.current.prev_month
      elsif message.match?(/\bnext month\b/i)
        Date.current.next_month
      end
      if relative_month
        return @date_scope = { type: :months, months: [ relative_month.month ], year: relative_month.year }
      end

      iso_tokens = message.scan(/\b(\d{4})-(\d{1,2})-(\d{1,2})\b/)
      iso_dates = iso_tokens.filter_map do |year, month, day|
        Date.new(year.to_i, month.to_i, day.to_i)
      rescue Date::Error
        nil
      end
      return invalidate_date_scope if iso_dates.length != iso_tokens.length
      if iso_dates.length >= 2 && message.match?(/\b(?:from|between)\b.{0,80}\b(?:to|through|and)\b/i)
        return @date_scope = { type: :exact_range, start: iso_dates.min, finish: iso_dates.max }
      end
      return @date_scope = { type: :exact, date: iso_dates.first } if iso_dates.one?

      date_tokens = message.scan(/\b(#{MONTH_PATTERN})\s+(\d{1,2})(?:(?:,\s*|\s+)(\d{4}))?\b/i)
      shared_years = date_tokens.filter_map { |_month, _day, year| year.presence&.to_i }.uniq
      valid_date_tokens = date_tokens.all? do |month, day, year|
        validation_year = year.presence&.to_i || (shared_years.one? ? shared_years.first : 2000)
        Date.valid_date?(validation_year, month_number(month), day.to_i)
      end
      return invalidate_date_scope unless valid_date_tokens
      if date_tokens.length >= 2 && message.match?(/\b(?:from|between)\b.{0,80}\b(?:to|through|and)\b/i)
        if date_tokens.all? { |_month, _day, year| year.present? }
          dates = date_tokens.map { |month, day, year| Date.new(year.to_i, month_number(month), day.to_i) }
          return @date_scope = { type: :exact_range, start: dates.min, finish: dates.max }
        end

        year = shared_years.one? ? shared_years.first : nil
        return @date_scope = {
          type: :month_day_range,
          start: [ month_number(date_tokens.first[0]), date_tokens.first[1].to_i ],
          finish: [ month_number(date_tokens.last[0]), date_tokens.last[1].to_i ],
          year: year
        }
      end
      if date_tokens.one? && date_tokens.first[2].blank?
        return @date_scope = { type: :month_day_exact, month: month_number(date_tokens.first[0]), day: date_tokens.first[1].to_i }
      end

      full_dates = date_tokens.filter_map do |month, day, year|
        next if year.blank?

        Date.new(year.to_i, month_number(month), day.to_i)
      rescue Date::Error
        nil
      end.compact
      return @date_scope = { type: :exact, date: full_dates.first } if full_dates.one?

      months = message.scan(/\b(#{MONTH_PATTERN})\b/i).flatten.map { |month| month_number(month) }.uniq
      year = message[/\b(20\d{2}|19\d{2})\b/, 1]&.to_i
      return @date_scope = { type: :months, months: months, year: year } if months.any?
      return @date_scope = { type: :year, year: year } if year

      @date_scope = nil
    end

    def invalidate_date_scope
      @invalid_date_scope = true
      @date_scope = nil
    end

    def invalid_date_scope?
      date_scope
      @invalid_date_scope == true
    end

    def month_number(value)
      MONTH_NUMBERS.fetch(value.to_s.downcase.first(3))
    end

    def setup_row_label(row)
      values = []
      values << money(row[:amount_cents]) if row[:amount_cents]
      values << "balance #{money(row[:balance_cents])}" if row[:balance_cents]
      values << "payment #{money(row[:payment_cents])}" if row[:payment_cents]
      values << "#{row[:interest_rate_percent]}% APR" if row[:interest_rate_percent]
      values << row[:cadence] if row[:cadence].present?
      "#{row.fetch(:label)}: #{values.join(', ')} (#{row.fetch(:state)})"
    end

    def status_label(status)
      status == "pending" ? "pending review" : status.to_s.humanize.downcase
    end

    def formatted_date(date)
      date&.strftime("%b %-d, %Y") || "date unavailable"
    end

    def money(cents) = Money.plain(cents)
  end
end
