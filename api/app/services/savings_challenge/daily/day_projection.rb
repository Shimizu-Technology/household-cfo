module SavingsChallenge
  module Daily
    class DayProjection
      def initialize(enrollment, user:, local_on:)
        @enrollment, @user, @requested_date = enrollment, user, local_on
      end

      def call
        ReadPolicy.call!(@enrollment, user: @user)
        @date = Inputs.elapsed_date!(@enrollment, @requested_date)
        check_in = SavingsDailyCheckIn.find_by(savings_enrollment: @enrollment, local_on: @date)
        version = check_in&.current_version
        purchases = SavingsDailyPurchaseVersion.joins(:savings_daily_purchase).where(savings_enrollment: @enrollment, purchased_on: @date, disposition: "purchase")
          .where("savings_daily_purchase_versions.id = savings_daily_purchases.current_version_id").includes(:household_transaction).to_a
        canonical = CanonicalPurchase.new(@enrollment)
        stale = purchases.count do |purchase|
          canonical.validate_previous!(purchase, lock: false)
          false
        rescue ArgumentError
          true
        end
        known = stale.zero? && (purchases.any? || version&.spending_state == "no_spend")
        { local_on: @date.iso8601, scope: "participant_daily_reports", spending_state: version&.spending_state || "unknown",
          check_in_id: check_in&.id, check_in_version_id: version&.id, check_in_lock_version: check_in&.lock_version || 0,
          completed_at: version&.approved_at&.iso8601, approved_purchase_count: purchases.size,
          reported_spend_cents: known ? purchases.sum(&:amount_cents) : nil, canonical_links_changed: stale.positive?,
          no_spend_discrepancy: version&.spending_state == "no_spend" && purchases.any?,
          all_account_completeness: "unknown" }
      end
    end
  end
end
