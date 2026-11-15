require "csv"

module FinancialDocuments
  # Re-derive a spreadsheet from its private, already-read cell evidence. A sign
  # answer appends a revision; it neither edits old facts nor approves purchases.
  class SpreadsheetSignAnswer
    def self.call(revision, negative_is_money_out:, user:)
      raise ArgumentError, "Choose how amounts are shown." unless [ true, false, nil, "all_out", "all_in", "individual" ].include?(negative_is_money_out)
      choice = negative_is_money_out
      derived = choice.nil?
      negative_is_money_out = nil if choice == "individual"
      document = revision.financial_document_import
      raise ArgumentError, "The original file is no longer available. Review each line’s money out or money in question." unless document&.source_available?
      raise ArgumentError, "This file does not need a sign answer." unless (revision.coverage["signed_amount_question"] == true || revision.coverage["signed_amount_answerable"] == true) && document&.spreadsheet? && document.source_available?
      raise ArgumentError, "This file already has approved lines. Review those lines individually." if SourceReviewHead.where(financial_source_event_id: revision.financial_source_events.select(:id)).where.not(approved_version_id: nil).exists?
      accounts = revision.financial_source_accounts.includes(:financial_source_evidence).order(:id).to_a
      identities = SourceAccountReviewHead.where(financial_source_account_id: accounts.map(&:id)).includes(approved_version: :source_tracked_account).index_by(&:financial_source_account_id)
      bases = accounts.map { |account| identities[account.id]&.approved_version&.source_tracked_account&.account_basis || account.account_basis }.uniq
      raise ArgumentError, "Say whether this is a bank account or a credit card first." unless bases.one? && bases.first.in?(%w[asset liability])
      target_rows = revision.coverage["signed_amount_target_rows"]
      originals = revision.financial_source_events.includes(:financial_source_evidence).order(:position).to_a
      # Earlier revisions did not retain the exact file-question target set.
      # Do not reinterpret already-established directions in those histories.
      target_rows ||= originals.select { |event| event.limitations.include?("transaction_direction_unclear") }.map(&:row_identity)
      if derived
        factor = revision.coverage["signed_amount_balance_factor"]
        return revision unless [ 1, -1 ].include?(factor)
        negative_is_money_out = StructuredSpreadsheetExtractor.negative_is_money_out(factor: factor, basis: bases.first, negative_balances: revision.coverage["signed_amount_negative_balances"] == true)
      elsif choice.in?(%w[all_out all_in])
        raise ArgumentError, "Review each line individually when amounts use both signs." unless revision.coverage["signed_amount_single_sign"] == true
        first = originals.find { |event| target_rows.include?(event.row_identity) }
        negative = first.financial_source_evidence.payload["source_amount_text"].to_s.strip.start_with?("-", "(")
        negative_is_money_out = choice == "all_out" ? negative : !negative
      end
      target_accounts = originals.select { |event| target_rows.include?(event.row_identity) }.map(&:financial_source_account_id).uniq
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
      result = StructuredSpreadsheetExtractor.new(file_path: file.path, filename: "sign-answer.csv", document_kind: document.document_kind,
        negative_is_money_out: choice == "individual" ? nil : negative_is_money_out, account_basis: bases.first).call
      raise ArgumentError, "We could not apply that answer. Nothing changed." unless result.success?
      accounting = result.data.fetch(:source_accounting)
      accounting[:coverage] = revision.coverage.deep_symbolize_keys.merge(signed_amount_question: false, signed_amount_answerable: choice != "individual", signed_amount_target_rows: target_rows, signed_amount_choice: choice, signed_amount_derived_convention: nil, signed_amount_convention: negative_is_money_out, signed_amount_convention_source: derived ? "balance" : "answer")
      raise ArgumentError, "We could not account for every line. Nothing changed." unless accounting[:events].length == originals.length
      accounting[:accounts].each do |account|
        original = accounts.find { |row| Digest::SHA256.hexdigest(row.id.to_s) == account[:source_key] }
        raise ArgumentError, "We could not match an account. Nothing changed." unless original
        account.merge!(original.attributes.except("id", "household_id", "financial_extraction_revision_id", "created_at", "updated_at").symbolize_keys)
        account[:account_basis] = bases.first
        account[:limitations] = original.limitations - [ "account_basis_unknown" ]
        account[:source_key] = original.source_key
        account[:evidence] = original.financial_source_evidence&.payload.to_h.deep_symbolize_keys
        label = identities[original.id]&.approved_version&.source_tracked_account&.label
        account[:evidence][:label] = label if label.present?
      end
      accounting[:events].zip(originals).each do |event, original|
        unless target_rows.include?(original.row_identity)
          event.merge!(original.attributes.except("id", "household_id", "financial_extraction_revision_id", "financial_source_account_id", "created_at", "updated_at").symbolize_keys)
        end
        if choice == "individual" && target_rows.include?(original.row_identity)
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
      document.update!(metadata: document.metadata.merge("source_accounting_revision_id" => persisted[:revision].id,
        "source_accounting_review_pending" => true, "source_reconciliation" => persisted[:reconciliation],
        "signed_amount_answer" => { "choice" => choice, "source" => derived ? "balance" : "answer", "negative_is_money_out" => negative_is_money_out, "user_id" => user.id, "previous_revision_id" => revision.id, "revision_id" => persisted[:revision].id, "answered_at" => Time.current.iso8601 },
        "signed_amount_answers" => Array(document.metadata["signed_amount_answers"]) + [ { "choice" => choice, "source" => derived ? "balance" : "answer", "negative_is_money_out" => negative_is_money_out, "user_id" => user.id,
          "previous_revision_id" => revision.id, "revision_id" => persisted[:revision].id, "answered_at" => Time.current.iso8601 } ]))
      persisted[:revision]
    ensure
      file&.close!
    end
  end
end
