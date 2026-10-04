module SavingsChallenge
  module Daily
    class CanonicalPurchase
      def self.digest(transaction)
        HouseholdFinance::Operations::PreparedOperation.fingerprint(
          transaction.attributes.slice("id", "household_id", "occurred_on", "merchant", "total_amount_cents", "status", "financial_source_event_id", "updated_at")
            .merge("splits" => transaction.transaction_splits.order(:id).pluck(:budget_category_id, :amount_cents)))
      end

      def initialize(enrollment)
        @enrollment = enrollment
      end

      def purchase_dates(transaction) = allowed_dates(transaction)

      def categories!(splits)
        splits.each do |split|
          category = @enrollment.household.budget_categories.find(split.fetch("budget_category_id"))
          raise ArgumentError, "Choose an active specific category" unless category.active? && !category.name.match?(/\A(?:uncategorized|needs category)\z/i)
        end
      end

      def validate_previous!(previous, lock: true)
        transaction = previous.household_transaction
        transaction.lock! if lock
        expected = previous.splits.map { |part| [ part.fetch("budget_category_id"), part.fetch("amount_cents") ] }.sort
        unless transaction.status.in?(%w[confirmed reconciled]) && transaction.total_amount_cents == previous.amount_cents && transaction.merchant == previous.merchant &&
            allowed_dates(transaction).include?(previous.purchased_on) && transaction.transaction_splits.pluck(:budget_category_id, :amount_cents).sort == expected
          raise ArgumentError, "The canonical purchase changed independently; reconcile it explicitly before another daily correction"
        end
      end

      def link!(transaction_id, expected_digest:, draft:, purchase:)
        transaction = @enrollment.household.household_transactions.lock.find(transaction_id)
        raise ArgumentError, "Canonical purchase changed; review its current facts" unless digest_matches?(transaction, expected_digest) && transaction.status.in?(%w[confirmed reconciled])
        if SavingsDailyPurchaseVersion.joins(:savings_daily_purchase).where(savings_enrollment_id: @enrollment.id, household_transaction_id: transaction.id)
            .where("savings_daily_purchase_versions.id = savings_daily_purchases.current_version_id").where.not(savings_daily_purchase_id: purchase.id).exists?
          raise ArgumentError, "This canonical purchase is already linked to this participant's daily record"
        end
        dates = allowed_dates(transaction)
        canonical_splits = transaction.transaction_splits.pluck(:budget_category_id, :amount_cents).sort
        requested = draft.splits.map { |part| [ part.fetch("budget_category_id"), part.fetch("amount_cents") ] }.sort
        unless transaction.total_amount_cents == draft.amount_cents && transaction.merchant == draft.merchant && dates.include?(draft.purchased_on) && canonical_splits == requested
          raise ArgumentError, "Link the canonical facts exactly; review source corrections through their existing source workflow"
        end
        transaction
      end

      def publish!(draft, previous:)
        categories!(draft.splits)
        retire_owned!(previous, expected_digest: draft.previous_canonical_digest) if previous
        year = @enrollment.household.budget_years.find_or_create_by!(year: draft.purchased_on.year)
        start = draft.purchased_on.beginning_of_month
        period = year.budget_periods.find_or_create_by!(starts_on: start) { |record| record.ends_on = start.end_of_month }
        transaction = @enrollment.household.household_transactions.create!(budget_period: period, occurred_on: draft.purchased_on,
          merchant: draft.merchant, total_amount_cents: draft.amount_cents, source_type: "manual_ui", status: "confirmed",
          metadata: { "savings_daily_purchase_id" => draft.savings_daily_purchase_id })
        draft.splits.each do |part|
          transaction.transaction_splits.create!(budget_category_id: part.fetch("budget_category_id"), amount_cents: part.fetch("amount_cents"))
        end
        transaction.validate_split_total!
        transaction
      end

      def retire_owned!(previous, expected_digest:, replacement: nil)
        raise ArgumentError, "Void requires a previous approved manual purchase" unless previous
        old = previous.household_transaction
        raise ArgumentError, "Source-owned purchases require their source review workflow" unless previous.link_kind == "manual_new" && old.financial_source_event_id.nil? && old.metadata["savings_daily_purchase_id"] == previous.savings_daily_purchase_id
        old.lock!
        raise ArgumentError, "Canonical purchase changed; review its current facts" unless digest_matches?(old, expected_digest) && old.status.in?(%w[confirmed reconciled])
        old.update!(status: "ignored") unless replacement&.id == old.id
      end

      private

      def allowed_dates(transaction)
        return [ transaction.occurred_on ] unless transaction.financial_source_event_id

        projection = SourceProjectionRevision.where(household_id: @enrollment.household_id, replacement_transaction_id: transaction.id, action: %w[create replace])
          .includes(source_review_version: [ :source_review_head, :source_account_identity_version ]).order(:id).last
        version = projection&.source_review_version
        current = version && version.household_id == @enrollment.household_id && version.financial_source_event.id == transaction.financial_source_event_id &&
          version.source_review_head.approved_version_id == version.id && version.source_account_identity_version.source_account_review_head.approved_version_id == version.source_account_identity_version_id &&
          version.expense? && version.purchase_amount_cents == transaction.total_amount_cents && version.merchant == transaction.merchant && version.posted_on == transaction.occurred_on
        raise ArgumentError, "Typed source purchases require their current approved canonical source facts" unless current

        [ transaction.occurred_on, version.authorized_on ].compact
      end

      def digest_matches?(transaction, expected)
        expected.instance_of?(String) && expected.match?(/\A[0-9a-f]{64}\z/) && ActiveSupport::SecurityUtils.secure_compare(self.class.digest(transaction), expected)
      end
    end
  end
end
