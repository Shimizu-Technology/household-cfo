require "csv"

module FinancialDocuments
  # Re-derive a spreadsheet from its private, already-read cell evidence. A sign
  # answer appends a revision; it neither edits old facts nor approves purchases.
  class SpreadsheetSignAnswer
    def self.saved_decisions?(revision)
      SourceReviewHead.where(financial_source_event_id: revision.financial_source_events.select(:id)).where.not(approved_version_id: nil).exists?
    end

    # A file with several accounts asks once for each account whose signed
    # amounts it leaves unclear. A single-account file keeps its file question.
    # Once a line is approved (or the file is gone) only her answers remain, for reading.
    def self.account_questions(revision)
      coverage = revision.coverage
      return [] if coverage["signed_amount_question"] == true || coverage["signed_amount_answerable"] == true
      document = revision.financial_document_import
      return [] unless document&.spreadsheet?
      accounts = revision.financial_source_accounts.order(:id).to_a
      return [] unless accounts.many?
      answerable = document.source_available? && !saved_decisions?(revision)
      answers = coverage["signed_amount_account_answers"].to_h
      events = revision.financial_source_events.includes(:financial_source_evidence).order(:position).to_a
      targets = target_rows(revision, events)
      accounts.filter_map do |account|
        # The lines whose direction the file itself left unclear. A balance-proven or labelled line never takes her answer.
        rows = events.select { |event| event.financial_source_account_id == account.id && event.row_kind != "informational" && targets.include?(event.row_identity) && unclear_as_read?(event) }
        answer = answers[account.source_key]
        next unless answer || (answerable && rows.any? { |event| event.limitations.include?("transaction_direction_unclear") })
        signs = rows.filter_map { |event| HouseholdFinance::Money.document_cents(event.financial_source_evidence&.payload.to_h["source_amount_text"], allow_negative: true) }.reject(&:zero?).map(&:negative?).uniq
        { account: account, single_sign: signs.length == 1, answer: answer, answerable: answerable, lines: rows }
      end
    end

    # Evidence keeps the first reading, so a line she already answered can take a changed answer.
    def self.unclear_as_read?(event)
      event.limitations.include?("transaction_direction_unclear") ||
        Array(event.financial_source_evidence&.payload.to_h["extraction_limitations"]).include?("transaction_direction_unclear")
    end

    # Earlier revisions did not retain the exact file-question target set.
    # Do not reinterpret already-established directions in those histories.
    def self.target_rows(revision, events)
      revision.coverage["signed_amount_target_rows"] || events.select { |event| event.limitations.include?("transaction_direction_unclear") }.map(&:row_identity)
    end

    # source_account_id: answer for that one account of a multi-account file. Every other line is kept exactly as it is.
    def self.call(revision, negative_is_money_out:, user:, source_account_id: nil)
      raise ArgumentError, "Choose how amounts are shown." unless [ true, false, nil, "all_out", "all_in", "individual" ].include?(negative_is_money_out)
      choice = negative_is_money_out
      derived = choice.nil?
      negative_is_money_out = nil if choice == "individual"
      document = revision.financial_document_import
      raise ArgumentError, "The original file is no longer available. Review each line’s money out or money in question." unless document&.source_available?
      unless source_account_id || ((revision.coverage["signed_amount_question"] == true || revision.coverage["signed_amount_answerable"] == true) && document.spreadsheet?)
        raise ArgumentError, "This file does not need a sign answer."
      end
      raise ArgumentError, "This file already has approved lines. Review those lines individually." if saved_decisions?(revision)
      accounts = revision.financial_source_accounts.includes(:financial_source_evidence).order(:id).to_a
      identities = SourceAccountReviewHead.where(financial_source_account_id: accounts.map(&:id)).includes(approved_version: :source_tracked_account).index_by(&:financial_source_account_id)
      basis_for = accounts.to_h { |account| [ account.id, identities[account.id]&.approved_version&.source_tracked_account&.account_basis || account.account_basis ] }
      originals = revision.financial_source_events.includes(:financial_source_evidence).order(:position).to_a
      target_rows = target_rows(revision, originals)
      if source_account_id
        question = account_questions(revision).find { |row| row[:account].id.to_s == source_account_id.to_s && row[:answerable] }
        raise ArgumentError, "This account does not need a sign answer." unless question
        raise ArgumentError, "Choose how amounts are shown." if derived
        scope = question[:account]
        raise ArgumentError, "Say whether this is a bank account or a credit card first." unless basis_for[scope.id].in?(%w[asset liability])
        single_sign = question[:single_sign]
      else
        bases = basis_for.values.uniq
        raise ArgumentError, "Say whether this is a bank account or a credit card first." unless bases.one? && bases.first.in?(%w[asset liability])
        single_sign = revision.coverage["signed_amount_single_sign"] == true
      end
      # Only these lines take her answer; every other line is copied as it is.
      answered_rows = (scope ? question[:lines] : originals.select { |event| target_rows.include?(event.row_identity) }).map(&:row_identity).to_set
      if derived
        factor = revision.coverage["signed_amount_balance_factor"]
        return revision unless [ 1, -1 ].include?(factor)
        negative_is_money_out = StructuredSpreadsheetExtractor.negative_is_money_out(factor: factor, basis: basis_for.values.first, negative_balances: revision.coverage["signed_amount_negative_balances"] == true)
      elsif choice.in?(%w[all_out all_in])
        raise ArgumentError, "Review each line individually when amounts use both signs." unless single_sign
        # A blank or zero row has no sign to read: take it from the first row that has an amount.
        amounts = originals.select { |event| answered_rows.include?(event.row_identity) }.map { |event| event.financial_source_evidence&.payload.to_h["source_amount_text"] }
        first = amounts.filter_map { |text| HouseholdFinance::Money.document_cents(text, allow_negative: true) }.find(&:nonzero?)
        raise ArgumentError, "We could not apply that answer. Nothing changed." unless first
        negative = first.negative?
        negative_is_money_out = choice == "all_out" ? negative : !negative
      end
      target_accounts = originals.select { |event| answered_rows.include?(event.row_identity) }.map(&:financial_source_account_id).uniq
      raise ArgumentError, "Review each account’s money out or money in lines individually." unless target_accounts.one?
      file = Tempfile.new([ "spreadsheet-sign", ".csv" ])
      file.write(CSV.generate do |csv|
        csv << %w[Date Description Amount Direction Category Account]
        originals.each do |event|
          evidence = event.financial_source_evidence&.payload || {}
          fields = evidence["source_fields"] || {}
          csv << [ fields["source_posted_on"], evidence["merchant"], evidence["source_amount_text"], fields["source_direction"], evidence["category_name"], event.financial_source_account_id ]
        end
      end)
      file.flush
      convention = choice == "individual" ? nil : negative_is_money_out
      # The rewritten file's Account cell is the account's id.
      result = StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "sign-answer.csv", document_kind: document.document_kind,
        negative_is_money_out: scope ? nil : convention, account_basis: scope ? nil : basis_for.values.first,
        account_conventions: scope && !convention.nil? ? { scope.id.to_s => convention } : {}).call
      raise ArgumentError, "We could not apply that answer. Nothing changed." unless result.success?
      accounting = result.data.fetch(:source_accounting)
      accounting[:coverage] = if scope
        answers = revision.coverage["signed_amount_account_answers"].to_h.merge(scope.source_key => { "choice" => choice, "negative_is_money_out" => convention })
        revision.coverage.deep_symbolize_keys.merge(signed_amount_target_rows: target_rows, signed_amount_account_answers: answers)
      else
        revision.coverage.deep_symbolize_keys.merge(signed_amount_question: false, signed_amount_answerable: true, signed_amount_target_rows: target_rows, signed_amount_choice: choice, signed_amount_derived_convention: nil, signed_amount_convention: negative_is_money_out, signed_amount_convention_source: derived ? "balance" : "answer")
      end
      raise ArgumentError, "We could not account for every line. Nothing changed." unless accounting[:events].length == originals.length
      accounting[:accounts].each do |account|
        original = accounts.find { |row| Digest::SHA256.hexdigest(row.id.to_s) == account[:source_key] }
        raise ArgumentError, "We could not match an account. Nothing changed." unless original
        account.merge!(original.attributes.except("id", "household_id", "financial_extraction_revision_id", "created_at", "updated_at").symbolize_keys)
        account[:account_basis] = basis_for[original.id]
        account[:limitations] = basis_for[original.id].in?(%w[asset liability]) ? original.limitations - [ "account_basis_unknown" ] : original.limitations
        account[:source_key] = original.source_key
        account[:evidence] = original.financial_source_evidence&.payload.to_h.deep_symbolize_keys
        label = identities[original.id]&.approved_version&.source_tracked_account&.label
        account[:evidence][:label] = label if label.present?
      end
      accounting[:events].zip(originals).each do |event, original|
        unless answered_rows.include?(original.row_identity)
          event.merge!(original.attributes.except("id", "household_id", "financial_extraction_revision_id", "financial_source_account_id", "created_at", "updated_at").symbolize_keys)
        end
        if choice == "individual" && answered_rows.include?(original.row_identity)
          event[:signed_amount_cents] = nil
          event[:expense_amount_cents] = nil
          event[:event_type] = "unknown"
          event[:row_kind] = "unresolved"
          event[:limitations] = (event[:limitations] + [ "transaction_direction_unclear" ]).uniq
        end
        if original.row_kind == "informational"
          event[:row_kind] = "informational"
          event[:event_type] = original.event_type
          event[:limitations] = original.limitations
          event[:signed_amount_cents] = nil
          event[:expense_amount_cents] = nil
        end
        event[:authorized_on] = original.authorized_on&.iso8601
        event[:source_key] = original.financial_source_account.source_key
        event[:locator] = original.locator.deep_symbolize_keys
        event[:row_identity] = original.row_identity
        event[:evidence] = original.financial_source_evidence.payload.deep_symbolize_keys
      end
      persisted = SourceAccountingPersister.new(document, attempt: nil, accounting: accounting, structured_spreadsheet: true).call
      # Keep the account she already chose, including a deliberately generic
      # name. Matching that name afresh could create or merge a different account.
      domain = SourceReview::Domain.new(document.household, user: user)
      persisted[:revision].financial_source_accounts.each do |account|
        original = accounts.find { |row| row.source_key == account.source_key }
        identity = identities[original.id]&.approved_version
        next unless identity
        input = { source_account_id: account.id, tracked_account_id: identity.source_tracked_account_id,
          base_version_id: nil, base_lock_version: 0, statement_facts: identity.statement_facts,
          reason: "Kept the account you chose while applying your file sign answer." }
        domain.execute("account_link", domain.normalize("account_link", input))
      end
      HouseholdFinance::DocumentTransactionDraftPersister.new(document, persisted.fetch(:transaction_drafts)).call
      answer = { "choice" => choice, "source" => derived ? "balance" : "answer", "negative_is_money_out" => negative_is_money_out, "user_id" => user.id,
        "previous_revision_id" => revision.id, "revision_id" => persisted[:revision].id, "answered_at" => Time.current.iso8601 }
      answer["source_account_id"] = scope.id if scope
      document.update!(metadata: document.metadata.merge("source_accounting_revision_id" => persisted[:revision].id,
        "source_accounting_review_pending" => true, "source_reconciliation" => persisted[:reconciliation],
        "signed_amount_answer" => answer, "signed_amount_answers" => Array(document.metadata["signed_amount_answers"]) + [ answer ]))
      persisted[:revision]
    ensure
      file&.close!
    end
  end
end
