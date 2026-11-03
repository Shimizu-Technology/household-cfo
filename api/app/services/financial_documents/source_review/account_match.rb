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

      # The account already tracked under this label (spacing and capitals aside) and basis, or nil.
      def existing(household, label, basis)
        SourceTrackedAccount.current_picture.where(household: household, account_basis: basis)
          .where("lower(regexp_replace(btrim(label), '\\s+', ' ', 'g')) = ?", label.to_s.squish.downcase).order(:id).first
      end
    end
  end
end
