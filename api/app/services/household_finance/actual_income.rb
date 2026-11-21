module HouseholdFinance
  # Income sources/schedules are plans; HouseholdTransaction records purchases.
  class ActualIncome
    def initialize(household)
      @household = household
    end

    def month(date)
      first, last = date.beginning_of_month, date.end_of_month
      accounts = identities.select do |identity|
        from, to = identity.statement_facts.values_at("period_start_on", "period_end_on")
        from.present? && to.present? && from <= last.iso8601 && to >= first.iso8601
      end
      rows = reader[:canonical_rows].select do |row|
        row[:account_identity_current] && tracked_ids.include?(row[:tracked_account_id]) &&
          row[:disposition] == "include" && row[:event_type] == "income" && row[:signed_amount_cents].to_i.positive? &&
          row[:posted_on].present? && Date.iso8601(row[:posted_on]).between?(first, last)
      end
      known = rows.any? || accounts.any? { |identity| approved_account?(identity) }
      covered = accounts.select do |identity|
        facts = identity.statement_facts
        facts["period_start_on"] <= first.iso8601 && facts["period_end_on"] >= last.iso8601 && approved_account?(identity, complete: true)
      end.map(&:source_tracked_account_id).uniq
      partial = (tracked_ids - covered).any? || unrepresented_accounts?
      open = last >= Time.current.in_time_zone("Pacific/Guam").to_date
      note = if !known
        "No statements approved for this month yet."
      elsif partial
        "Statements do not cover the whole month for every account. This is only the income approved so far."
      else
        "From the statements you approved; other income may be missing."
      end
      note += " This month is still open." if open
      { actual_cents: known ? rows.sum { |row| row[:signed_amount_cents] } : nil,
        partial: partial, month_open: open, coverage_note: note }
    end

    private

    def tracked_ids
      @tracked_ids ||= SourceTrackedAccount.where(household: @household).current_picture.pluck(:id)
    end

    def unrepresented_accounts?
      linked = SourceTrackedAccount.where(household: @household, id: tracked_ids).where.not(account_id: nil).select(:account_id)
      @household.accounts.active.where.not(id: linked).exists?
    end

    def identities
      @identities ||= SourceAccountReviewHead.where(household: @household).includes(:approved_version).filter_map(&:approved_version)
        .select { |identity| tracked_ids.include?(identity.source_tracked_account_id) }
    end

    def reader
      @reader ||= FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(
        revision_ids: FinancialExtractionRevision.where(household: @household).pluck(:id))
    end

    def approved_account?(identity, complete: false)
      revision_id = identity.source_account_review_head.financial_source_account.financial_extraction_revision_id
      status = reader[:revisions].find { |row| row[:id] == revision_id }
      status && status[:participant_approved] && (!complete || status[:coverage_status] == "complete")
    end
  end
end
