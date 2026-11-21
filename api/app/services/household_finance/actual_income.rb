module HouseholdFinance
  # What came in, from the statement lines she approved. Income sources and schedules are the plan; this is what arrived.
  # Only money into her deposit accounts counts: a card or loan payment, money moved between her own accounts and a
  # refund never do. A month is complete only when approved statements cover every day of it for every deposit account.
  # Unknown is never $0: a month with nothing approved, or with $0 only because statements miss part of it, is unknown.
  class ActualIncome
    # Accounts she keeps money in. Retirement, investment and property accounts are not where pay arrives.
    NOT_DEPOSIT = %w[retirement investment property].freeze
    INCOME_TYPES = %w[income interest].freeze

    # A plan carries one of these; the approved lines are read once, and only when a month is shown.
    class Months
      def initialize(income, year)
        @income, @year, @months = income, year, {}
      end

      def [](month) = @months[month.to_i] ||= @income.month(Date.new(@year, month.to_i, 1))
      def fetch(month) = self[month]
      def to_h = (1..12).to_h { |month| [ month, self[month] ] }
      def as_json(*) = to_h.as_json
      def ==(other) = other.respond_to?(:to_h) && to_h == other.to_h
    end

    def initialize(household, today: Time.current.in_time_zone("Pacific/Guam").to_date)
      @household, @today = household, today
    end

    def year(year) = Months.new(self, year)

    def month(date)
      first, last = date.beginning_of_month, date.end_of_month
      rows = income_rows.select { |row| Date.iso8601(row[:posted_on]).between?(first, last) }
      total = rows.sum { |row| row[:signed_amount_cents] }
      seen = deposit_ids.any? { |id| covered_days(id, first, last).any? }
      covered = deposit_ids.count { |id| covered_days(id, first, last, complete: true).length == last - first + 1 }
      partial = deposit_ids.empty? || covered < deposit_ids.length || unrepresented_accounts?
      actual = (rows.any? || seen) && !(partial && total.zero?) ? total : nil
      open = @today.between?(first, last)
      note = if first > @today
        "This month has not started yet."
      elsif actual.nil?
        seen ? "None approved yet. Your approved statements don’t cover all of this month." : "No statements approved for this month yet."
      elsif partial
        "Statements do not cover the whole month for every account. This is only the income approved so far."
      else
        "From the statements you approved; other income may be missing."
      end
      note += " This month is still open." if open
      { actual_cents: actual, partial: partial, month_open: open, coverage_note: note }
    end

    private

    def income_rows
      @income_rows ||= reader[:canonical_rows].select do |row|
        row[:account_identity_current] && deposit_ids.include?(row[:tracked_account_id]) && row[:account_basis] == "asset" &&
          row[:disposition] == "include" && row[:event_type].in?(INCOME_TYPES) && row[:signed_amount_cents].to_i.positive? &&
          row[:posted_on].present? && !row[:external_reference].to_s.start_with?(*FinancialDocuments::SourceReview::ParticipantPlan::UNFINISHED_REFERENCES)
      end
    end

    # Her own money accounts with statements in the current picture: asset accounts not linked to a retirement, investment or property account.
    def deposit_ids
      @deposit_ids ||= SourceTrackedAccount.where(household: @household, account_basis: "asset").current_picture
        .left_joins(:account).where("accounts.id IS NULL OR accounts.account_type NOT IN (?)", NOT_DEPOSIT).pluck(:id)
    end

    # A checking or savings account she added with no statements yet means the month can't be complete.
    def unrepresented_accounts?
      return @unrepresented if defined?(@unrepresented)
      linked = SourceTrackedAccount.where(household: @household).current_picture.where.not(account_id: nil).select(:account_id)
      @unrepresented = @household.accounts.active.current_picture.where(account_type: Account::LIQUID_TYPES).where.not(id: linked).exists?
    end

    def covered_days(id, first, last, complete: false)
      periods.fetch(id, []).select { |period| !complete || period[:complete] }
        .flat_map { |period| ([ period[:from], first ].max..[ period[:to], last ].min).to_a }.uniq
    end

    # The approved statement periods for each deposit account, from statements she approved.
    def periods
      @periods ||= begin
        statuses = reader[:revisions].index_by { |row| row[:id] }
        SourceAccountReviewHead.where(household: @household, financial_source_account_id: FinancialSourceAccount.where(financial_extraction_revision_id: revision_ids).select(:id))
          .includes(:approved_version, :financial_source_account).each_with_object({}) do |head, result|
          identity = head.approved_version
          next unless identity && deposit_ids.include?(identity.source_tracked_account_id)
          status = statuses[head.financial_source_account.financial_extraction_revision_id]
          from, to = identity.statement_facts.values_at("period_start_on", "period_end_on")
          next unless status&.dig(:participant_approved) && from.present? && to.present?
          (result[identity.source_tracked_account_id] ||= []) << { from: Date.iso8601(from), to: Date.iso8601(to), complete: status[:coverage_status] == "complete" }
        end
      end
    end

    def revision_ids
      @revision_ids ||= FinancialExtractionRevision.where(household: @household,
        financial_document_import_id: @household.financial_document_imports.current_picture.select(:id)).pluck(:id)
    end

    def reader
      @reader ||= FinancialDocuments::SourceReview::ApprovedSourceReader.new(@household).call(revision_ids: revision_ids, current_financial_picture: true)
    end
  end
end
