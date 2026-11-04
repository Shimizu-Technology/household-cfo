module SpendingPatterns
  # Reporting arithmetic only: no purchase, category or economic link is changed.
  # Explicit refund links take priority; their credit cannot also enter the
  # same-merchant pool. Only current, approved inflows in the selected window count.
  class RefundNetting
    def self.call(rows, source:, reviewed:)
      current = reviewed[:canonical_rows].select { |row| row[:account_identity_current] }.pluck(:id).to_set
      credits = source.select { |row| current.include?(row.id) && row.disposition == "include" && row.event_type == "refund" && row.signed_amount_cents.to_i.positive? }
      credit_ids = credits.map(&:id).to_set
      used = Hash.new(0)
      reviewed[:economic_groups].select { |group| group[:kind] == "refund" }.each do |group|
        original = group[:members].find { |member| member[:role] == "original_purchase" }
        credit = group[:members].find { |member| member[:role] == "refund" }
        next unless original && credit && credit_ids.include?(credit[:version_id])
        amount = credit[:allocation_cents]
        used[credit[:version_id]] += amount
        row = rows.find { |purchase| purchase[:source_version_id] == original[:version_id] }
        deduct!(row, amount) if row
      end
      credits.each do |credit|
        remaining = [ credit.signed_amount_cents - used[credit.id], 0 ].max
        key = merchant_key(credit.merchant)
        next unless key && remaining.positive?
        # This allocation is only for the observed report, newest purchases first;
        # it does not claim which order was returned or create an approved link.
        rows.select { |row| merchant_key(row[:merchant]) == key }.sort_by { |row| row[:date] }.reverse_each do |row|
          remaining -= deduct!(row, remaining)
          break if remaining.zero?
        end
      end
    end

    def self.merchant_key(value)
      text = FinancialDocuments::MerchantNormalizer.call(value).to_s.downcase.squish
      return if text.blank? || text == "unnamed purchase"
      # A known purchase descriptor and its bank refund/order descriptor name the
      # same merchant. Keep unrelated names (for example Amazon Cafe) separate.
      return "amazon" if text.match?(/\Aamazon(?:\s+marketplace|\s+(?:refund|return)(?:\s+order)?(?:\s+[a-z0-9-]+)?)?\z/)
      text
    end

    def self.deduct!(row, requested)
      before = row[:amount_cents]
      amount = [ requested, before ].min
      return 0 if amount.zero?
      remaining = amount
      row[:splits].each_with_index do |split, index|
        reduction = index == row[:splits].length - 1 ? remaining : amount * split[:amount_cents] / before
        split[:amount_cents] -= reduction
        remaining -= reduction
      end
      row[:amount_cents] -= amount
      amount
    end
    private_class_method :merchant_key, :deduct!
  end
end
