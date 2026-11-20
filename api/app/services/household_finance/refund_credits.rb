module HouseholdFinance
  # Money back from a refund she approved. A refund is never income and never a new purchase: it reduces the category of
  # the purchase it refunds, in the month the refund posts (Leon, 2026-11-19). Budget, the spending report and Mia all
  # read these credits, so they cannot disagree about a month or a category.
  #
  # Which purchase it refunds, in order:
  #   1. an approved refund link to the original statement purchase;
  #   2. the category she chose for the refund line when no purchase could be found;
  #   3. the most recent purchase at the same store, on or before the refund date, that counts in Budget.
  # A split purchase gives money back to each category in proportion. When none of these is known the refund counts
  # nowhere and the statement review keeps asking which category it goes back to; it is never guessed silently.
  class RefundCredits
    Credit = Struct.new(:version_id, :event_id, :posted_on, :merchant, :amount_cents, :allocations, :basis, :original, keyword_init: true) do
      def counted? = allocations.any?
    end
    # original: the purchase it refunds, when one was found ({ merchant:, occurred_on: }).

    def self.merchant_key(value)
      text = SpendingPatterns::MerchantName.matching_label(value).to_s.unicode_normalize(:nfkc).downcase.squish
      return if text.blank? || text == "unnamed purchase"
      # A known purchase descriptor and its bank refund/order descriptor name the
      # same merchant. Keep unrelated names (for example Amazon Cafe) separate.
      return "amazon" if text.match?(/\Aamazon(?:\s+marketplace|\s+(?:refund|return)(?:\s+order)?(?:\s+[a-z0-9-]+)?)?\z/)
      text
    rescue ArgumentError, Encoding::CompatibilityError
      nil
    end

    # Proportional shares that add up to exactly `cents`. Whole cents go first to the largest remainders, so rounding never
    # lands on a small split out of proportion.
    def self.proportional(parts, cents)
      total = parts.sum { |part| part[:amount_cents] }
      return [] unless total.positive? && cents.positive?
      shares = parts.map { |part| cents * part[:amount_cents] / total }
      order = parts.each_index.sort_by { |index| [ -((cents * parts[index][:amount_cents]) % total), -index ] }
      (cents - shares.sum).times { |step| shares[order[step % order.length]] += 1 }
      parts.each_with_index.map { |part, index| { category_id: part[:category_id], amount_cents: shares[index] } }.reject { |part| part[:amount_cents].zero? }
    end

    def initialize(household, from: nil, to: nil)
      @household, @from, @to = household, from&.to_date, to&.to_date
    end

    def call
      @call ||= versions.map { |version| credit_for(version) }
    end

    def counted = call.select(&:counted?)

    # { category_id => cents given back } for the dates asked about.
    def category_cents
      counted.each_with_object(Hash.new(0)) do |credit, sums|
        credit.allocations.each { |part| sums[part[:category_id]] += part[:amount_cents] }
      end
    end

    # { [category_id, period_id] => cents given back }, by the budget month the refund posted in.
    def by_category_and_period(periods)
      counted.each_with_object(Hash.new(0)) do |credit, sums|
        period = periods.find { |row| credit.posted_on.between?(row.starts_on, row.ends_on) }
        next unless period
        credit.allocations.each { |part| sums[[ part[:category_id], period.id ]] += part[:amount_cents] }
      end
    end

    # The credit for one approved refund version, wherever it posted.
    def for_version(version) = credit_for(version)

    # The purchase an unsaved refund line would go back to: the most recent one at the same store on or before it.
    def same_store_original(merchant, posted_on)
      key = self.class.merchant_key(merchant)
      return unless key && posted_on
      scope = household.household_transactions.where(status: %w[confirmed reconciled]).where(occurred_on: ..posted_on)
        .includes(:transaction_splits).order(occurred_on: :desc, id: :desc)
      word = key[/[a-z]{3,}/]
      scope = scope.where("household_transactions.merchant ILIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(word)}%") if word
      scope.to_a.find { |row| self.class.merchant_key(row.merchant) == key && counted_parts(row).any? }
    end

    # The categories a purchase counts in Budget, with what it counts for each.
    def counted_parts(transaction)
      transaction.transaction_splits.sort_by(&:id).select { |split| split.amount_cents.positive? && current_category_ids.include?(split.budget_category_id) }
        .map { |split| { category_id: split.budget_category_id, amount_cents: split.amount_cents } }
    end

    private

    attr_reader :household

    def versions
      scope = SourceReviewVersion
        .joins(source_review_head: { financial_source_event: :financial_extraction_revision }, source_account_identity_version: :source_account_review_head)
        .where(household_id: household.id, disposition: "include", event_type: "refund")
        .where("source_review_heads.approved_version_id = source_review_versions.id")
        .where("source_account_review_heads.approved_version_id = source_review_versions.source_account_identity_version_id")
        .where("source_review_versions.signed_amount_cents > 0")
        .where(financial_extraction_revisions: { financial_document_import_id: household.financial_document_imports.current_picture.select(:id) })
      scope = scope.where(posted_on: @from..) if @from
      scope = scope.where(posted_on: ..@to) if @to
      scope.includes(:budget_category, source_review_head: :financial_source_event).order(:posted_on, :id).to_a
    end

    def credit_for(version)
      remaining = version.signed_amount_cents
      allocations = []
      basis = nil
      original = nil
      linked_amounts(version).each do |purchase, cents|
        cents = [ cents, remaining ].min
        parts = purchase_parts(purchase)
        next if parts.empty? || cents <= 0
        allocations.concat(self.class.proportional(parts, cents))
        remaining -= cents
        basis ||= :linked
        original ||= { merchant: purchase.merchant, occurred_on: purchase.posted_on }
      end
      if remaining.positive?
        chosen = version.budget_category
        if chosen && current_category_ids.include?(chosen.id)
          allocations << { category_id: chosen.id, amount_cents: remaining }
          basis ||= :chosen
          remaining = 0
        # The same-store fallback is for a refund with nothing linked: the rest of a partly linked refund is never guessed.
        elsif basis.nil? && (purchase = same_store_original(version.merchant, version.posted_on))
          allocations.concat(self.class.proportional(counted_parts(purchase), remaining))
          basis ||= :same_store
          original ||= { merchant: purchase.merchant, occurred_on: purchase.occurred_on }
          remaining = 0
        end
      end
      # A link that covers only part of the refund leaves the rest unknown, never quietly dropped or guessed.
      allocations = [] if remaining.positive?
      Credit.new(version_id: version.id, event_id: version.source_review_head.financial_source_event_id, posted_on: version.posted_on,
        merchant: version.merchant, amount_cents: version.signed_amount_cents, allocations: merge(allocations), basis: (basis if allocations.any?), original: (original if allocations.any?))
    end

    def merge(allocations)
      allocations.group_by { |part| part[:category_id] }.map { |id, parts| { category_id: id, amount_cents: parts.sum { |part| part[:amount_cents] } } }
    end

    # [[original purchase version, cents]] from approved refund links that are still current.
    def linked_amounts(version)
      links.filter_map do |group|
        members = group.source_economic_memberships
        credit = members.find { |member| member.role == "refund" && member.source_review_version_id == version.id }
        original = members.find { |member| member.role == "original_purchase" }
        [ original.source_review_version, credit.allocation_cents ] if credit && original
      end
    end

    def links
      @links ||= FinancialDocuments::SourceReview::EconomicLinker.valid_current_versions(household).select { |group| group.kind == "refund" }
    end

    # What the original statement purchase counts as in Budget: its projection's splits, else the category it was approved with.
    def purchase_parts(version)
      projected = household.household_transactions.where(financial_source_event_id: version.source_review_head.financial_source_event_id, status: %w[confirmed reconciled])
        .includes(transaction_splits: :budget_category).order(:id).to_a
      return counted_parts(projected.first) if projected.one?
      category = version.budget_category
      return [] unless category && current_category_ids.include?(category.id) && version.purchase_amount_cents.to_i.positive?
      [ { category_id: category.id, amount_cents: version.purchase_amount_cents } ]
    end

    def current_category_ids
      @current_category_ids ||= household.budget_categories.pluck(:id).to_set
    end
  end
end
