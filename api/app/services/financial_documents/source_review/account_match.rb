module FinancialDocuments
  module SourceReview
    # Which account a statement belongs to, decided from its label.
    module AccountMatch
      module_function

      # A real label says which account it is ("BOG Everyday Checking", "Visa ····1234"). A fallback such as "Bank account" does not:
      # two files that only say that are two accounts, or a charge in one would be offered as a duplicate of the same charge in the other.
      def named?(label)
        label.include?("····") || AccountName.parts(label)[:name].present?
      end

      def default_label(account, basis)
        payload = account.financial_source_evidence&.payload || {}
        AccountName.default_label(payload["label"], payload["masked_identifier"], basis)
      end

      def candidates(household, basis = nil)
        scope = SourceTrackedAccount.current_picture.where(household: household).order(:id)
        basis ? scope.where(account_basis: basis) : scope
      end

      def suggested(household, label, basis, account:, allow_last_four: true)
        matches(household, label, basis, account: account, allow_last_four: allow_last_four).then { |rows| rows.first if rows.one? }
      end

      def ambiguous?(household, label, basis, account:, allow_last_four: true)
        account.limitations.include?("account_label_ambiguous") ||
          matches(household, label, basis, account: account, allow_last_four: allow_last_four).many?
      end

      def matches(household, label, basis, account:, allow_last_four:)
        return [] if account.limitations.include?("account_label_ambiguous") || !basis.in?(%w[asset liability])

        exact = named?(label) ? exact_matches(household, label, basis) : []
        return exact if exact.any? || !allow_last_four

        last4 = AccountName.parts(label)[:last4]
        last4 ? with_last_four(candidates(household, basis), last4) : []
      end

      def with_last_four(accounts, last4)
        accounts.select { |account| AccountName.parts(account.label)[:last4] == last4 }
      end

      # The account already tracked under this label (spacing and capitals aside) and basis, or nil.
      def existing(household, label, basis)
        matches = exact_matches(household, label, basis)
        matches.first if matches.one?
      end

      def exact_matches(household, label, basis)
        candidates(household, basis).where("lower(regexp_replace(btrim(label), '\\s+', ' ', 'g')) = ?", label.to_s.squish.downcase).limit(2).to_a
      end
    end
  end
end
