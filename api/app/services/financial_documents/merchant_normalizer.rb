# frozen_string_literal: true

module FinancialDocuments
  # Display/grouping only: retain the original descriptor as source evidence.
  # Known aliases are anchored after removing bank/card boilerplate, so a store
  # whose name merely contains Ross (for example Rosslyn Cafe) is not renamed.
  module MerchantNormalizer
    REGION = /(?:A[KLRSZ]|C[AOT]|D[CE]|FL|G[AU]|HI|I[ADLN]|K[SY]|LA|M[ADEHINOPST]|N[CDEHJMVY]|O[HKR]|P[ARW]|RI|S[CD]|T[NX]|UT|V[AIT]|W[AIVY]|AS|FM|MP)/i
    GUAM_LOCATION = /(?:Agana Heights|Agat|Asan(?:-Maina)?|Barrigada|Chalan Pago(?:-Ordot)?|Dededo|Hagatna|Hagåtña|Inalahan|Inarajan|Mangilao|Merizo|Mongmong(?:-Toto-Maite)?|Piti|Santa Rita(?:-Sumai)?|Sinajana|Talofofo|Tamuning|Umatac|Yigo|Yona|Guam)/i
    LOCATION = /(?:#{GUAM_LOCATION}(?:\s+GU)?|[[:alpha:]][[:alpha:].'’-]*(?:\s+[[:alpha:]][[:alpha:].'’-]*){0,4}\s+#{REGION})/i
    module_function

    def call(value)
      return if value.nil?
      text = value.to_s.unicode_normalize(:nfkc).gsub(/(?<!\w)(?:XXXX|\*{4})\s*\d{4}\b/i, "").squish
      prefix = /\A(?:POS\s+(?:DEBIT|PURCHASE)|DEBIT\s+CARD|CARD\s+PURCHASE)\s+/i
      if text.match?(prefix)
        text = text.sub(prefix, "")
        # A leading number may be the merchant's name (1776 Coffee). Only
        # remove a bank reference before a known merchant alias.
        without_reference = text.sub(/\A\d{4}\s+/i, "")
        text = without_reference if known_merchant(without_reference)
      end
      known_merchant(text) || text.presence || value.to_s.squish
    rescue ArgumentError, Encoding::CompatibilityError
      value.to_s
    end

    def known_merchant(text)
      return "Ross" if text.match?(/\ARoss(?:\s+Stores|\s+Dress for Less)?(?:\s*#\s*\d+)?(?:\s+#{LOCATION})?\z/i)
      return "Kmart" if text.match?(/\AKmart(?:\s*#\s*\d+)?(?:\s+#{LOCATION})?\z/i)
      nil
    end
  end
end
