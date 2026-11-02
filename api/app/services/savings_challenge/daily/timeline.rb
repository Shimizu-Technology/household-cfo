module SavingsChallenge
  module Daily
    # One bounded query per record type; no per-day projection or API request.
    class Timeline
      def initialize(enrollment)
        @enrollment = enrollment
      end

      def call
        check_ins = SavingsDailyCheckIn.where(savings_enrollment: @enrollment).includes(:current_version).index_by(&:local_on)
        purchases = SavingsDailyPurchase.where(savings_enrollment: @enrollment).includes(:current_version).filter_map(&:current_version)
          .select { |row| row.disposition == "purchase" }.group_by(&:purchased_on)
        entries = @enrollment.savings_entries.includes(:current_approved_version).filter_map(&:current_approved_version)
          .reject { |row| HouseholdFinance::SavingsProjection::EXCLUDED_FUNDING_SOURCES.include?(row.funding_source) }.group_by(&:effective_on)
        reviewed = SavingsCheckpoint.where(savings_enrollment: @enrollment).where.not(current_version_id: nil).pluck(:milestone_day)
        { days: (0...90).map do |offset|
            date = @enrollment.starts_on + offset
            version = check_ins[date]&.current_version
            { day: offset + 1, local_on: date.iso8601, future: date > @enrollment.local_today,
              check_in: version&.spending_state || "unknown", purchase_count: purchases.fetch(date, []).size,
              deposit_cents: entries.key?(date) ? entries[date].sum(&:signed_cents) : nil }
          end,
          checkpoints_due: [ 30, 60, 90 ].select { |day| @enrollment.starts_on + day - 1 <= @enrollment.local_today && !reviewed.include?(day) } }
      end
    end
  end
end
