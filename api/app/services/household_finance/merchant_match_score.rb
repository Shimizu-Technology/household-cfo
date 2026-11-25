require "set"

module HouseholdFinance
  # How alike two store names are, from 0.2 (different) to 1.0 (same), or 0.4 when one is missing.
  # Bank lines carry boilerplate a receipt doesn't ("POS PURCHASE PAYLESS SUPERMARKET #12 TAMUNING GU"),
  # so the cleaned store names are compared too. Used both ways round: a pending purchase against its bank
  # line (TransactionDraftMatcher) and a bank line against a purchase she already confirmed.
  module MerchantMatchScore
    module_function

    def call(left, right)
      raw = text_score(normalized(left), normalized(right))
      cleaned_left = cleaned(left)
      cleaned_right = cleaned(right)
      return raw if cleaned_left.blank? || cleaned_right.blank?

      [ raw, text_score(cleaned_left, cleaned_right, min_contained_length: 4) ].max
    end

    def text_score(left, right, min_contained_length: 1)
      return 0.4 if left.blank? || right.blank?
      return 1.0 if left == right
      return 0.88 if [ left.length, right.length ].min >= min_contained_length && (left.include?(right) || right.include?(left))

      overlap = token_overlap(left, right)
      overlap >= 0.5 ? overlap : 0.2
    end

    def cleaned(value)
      normalized(SpendingPatterns::MerchantName.call(value))
    end

    def normalized(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s]/, " ").squish
    end

    def token_overlap(left, right)
      left_tokens = left.split.to_set
      right_tokens = right.split.to_set
      return 0.0 if left_tokens.empty? || right_tokens.empty?

      (left_tokens & right_tokens).length.to_f / [ left_tokens.length, right_tokens.length ].max
    end
  end
end
