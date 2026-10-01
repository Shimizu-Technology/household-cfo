# frozen_string_literal: true

module Mia
  class ContentSafetyValidator
    MESSAGES = {
      "unsafe_instruction" => "Remove instructions that try to control Mia, bypass safeguards, invoke tools, or change approval behavior.",
      "personal_information" => "Remove personal or identifying information such as contact, address, tax, account, routing, or card details.",
      "household_fact" => "Rewrite household-specific balances, income, debts, transactions, or personal circumstances as general coaching guidance.",
      "regional_stereotype" => "Rewrite regional or cultural assumptions as coach-authored guidance that applies only in the stated context."
    }.freeze

    PII_PATTERNS = [
      /\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}\b/i,
      /(?<!\d)(?:\+?1[\s.\-]?)?(?:\(?\d{3}\)?[\s.\-]?)\d{3}[\s.\-]\d{4}(?!\d)/,
      /\b\d{3}([\s-])\d{2}\1\d{4}\b/,
      /\b(?:ssn|social security|tax id|tin|ein)\s*(?:number|no\.?|#)?\s*[:#-]?\s*\d[\d -]{3,16}\b/i,
      /\b(?:routing|account|member|policy|card)\s*(?:number|no\.?|#|ending in)\s*[:#-]?\s*\d[\d -]{3,23}\b/i,
      /\b\d{1,6}\s+[A-Z][A-Za-z.'\-]*(?:\s+[A-Z][A-Za-z.'\-]*){0,4}\s+(?:Street|St|Road|Rd|Avenue|Ave|Drive|Dr|Lane|Ln|Boulevard|Blvd|Court|Ct|Circle|Cir|Highway|Hwy)\b/i
    ].freeze
    HOUSEHOLD_FACT_PATTERNS = [
      /\b(?:my|our|we|i|the\s+(?:client|participant|household|family))\b.{0,60}\b(?:earn(?:s|ed)?|owe[sd]?|paid|spent|saved|received?|borrowed)\b.{0,40}(?:\$\s?\d[\d,]*(?:\.\d{1,2})?|\d[\d,]*\.\d{2}\b|\d[\d,]*\s*(?:dollars?|per\s+(?:month|year)|monthly|annually|\/month)\b)/i,
      /\b(?:my|our|the\s+(?:client|participant|household|family)['’]?s?)\s+(?:income|salary|(?:account\s+)?balance|budget|debt|rent|mortgage|payment|savings|transaction)\b.{0,24}\b(?:is|was|equals?|totals?|of)\b.{0,12}(?:\$\s?)?\d[\d,]*(?:\.\d{1,2})?\b/i,
      /\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?['’]s\b.{0,80}\b(?:income|salary|balance|debt|rent|mortgage|payment|transaction|account|budget|savings)\b/i,
      /\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\s+(?:owes?|earns?|makes?|paid|spent|saved)\b.{0,60}(?:\$\s?\d|\b\d[\d,]*(?:\.\d{1,2})?\b)/,
      /\b(?:my|our|we|i)\b.{0,50}\b(?:earn|make|income|salary|owe|debt|balance|saved)\b.{0,30}\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|million|six figures?)\b/i
    ].freeze
    REGIONAL_STEREOTYPE_PATTERN = /\b(?:(?:people|families|women|men|households|clients)\s+(?:from|in)\s+[A-Z][A-Za-z.'\- ]{1,40}|Guamanians?|Southerners?|Chamorro(?:s| people)?)\s+(?:always|never|all|typically|usually|often|naturally|tend\s+to|are\s+(?:all|just|simply))\b/i
    UNSAFE_INSTRUCTION_PATTERNS = [
      /\b(?:ignore|disregard|override)\b.{0,80}\b(?:previous|system|developer|instruction|safety|guardrail|policy)\b/i,
      /\b(?:reveal|show|print|repeat|expose)\b.{0,50}\b(?:system prompt|developer message|hidden instruction|tool call)\b/i,
      /\b(?:bypass|disable|remove|weaken|suppress)\b.{0,50}\b(?:safety|guardrail|policy|restriction|approval|crisis|988)\b/i,
      /\b(?:you are now|act as)\b.{0,50}\b(?:unrestricted|system|developer|administrator|admin|tool|function|human coach)\b/i,
      /\b(?:call|invoke|execute)\b.{0,40}\b(?:tool|function|command|api)\b/i,
      /\b(?:mia|assistant|agent|system)\s+(?:may|can|should|must)\s+(?:directly\s+|automatically\s+|silently\s+)?(?:write|create|update|delete|approve)\b.{0,60}\b(?:record|database|account|transaction|budget|household)\b/i,
      /\b(?:write|create|update|delete|approve)\b.{0,60}\b(?:database|stored records?|records?|accounts?|transactions?|budgets?|households?)\b.{0,60}\b(?:without approval|bypass approval|automatically|silently)\b/i,
      /\b(?:without approval|bypass approval|automatically|silently)\b.{0,50}\b(?:write|create|update|delete|approve)\b.{0,60}\b(?:database|stored records?|records?|accounts?|transactions?|budgets?|households?)\b/i,
      /\b(?:recommend|tell|instruct|urge|advise|direct)\b.{0,90}\b(?:buy|sell|invest|move|transfer|put|allocate)\b.{0,90}\b(?:bitcoin|crypto|meme coin|nft|options?|forex|futures?|penny stocks?|individual stocks?)\b/i,
      /\b(?:recommend|pick|name|select|buy|sell|invest\s+in|allocate|put)\b.{0,80}\b(?:[A-Z][A-Za-z&.-]*(?:\s+[A-Z][A-Za-z&.-]*){0,2})\s+(?:stocks?|shares?|securities?)\b/i,
      /\b(?:buy|sell|invest\s+in|allocate.{0,20}\bto|put.{0,30}\bin)\b.{0,80}\b(?-i:(?!(?:CD|FDIC|HSA|IRA|IRS|ROTH)\b)[A-Z]{2,5})\b/i,
      /\b(?:recommend|pick|name|select)\b.{0,80}\b(?-i:[A-Z]{2,5})\b.{0,20}\b(?:stock|shares?|security|ticker)\b/i,
      /\bbuy\b.{0,40}\b\d+\s+shares?\s+of\s+(?:[A-Z]{1,5}|[A-Z][a-z]+)\b/i,
      /\b(?:provide|give|offer|deliver)\b.{0,60}\b(?:financial|legal|tax|investment|accounting)\s+advice\b/i,
      /\b(?:guarantee(?:d)?|promise)\b.{0,80}\b(?:returns?|profits?|gains?|income|outcomes?|results?)\b|\b(?:returns?|profits?|gains?|income|outcomes?|results?)\b.{0,80}\b(?:are\s+)?guaranteed\b/i
    ].freeze

    class UnsafeContent < ArgumentError
      attr_reader :code

      def initialize(code)
        @code = code
        super(MESSAGES.fetch(code))
      end
    end

    class << self
      def validate!(title:, content:, topics: [])
        text = [ title, content, *Array(topics) ].join("\n").unicode_normalize(:nfkc)
        raise UnsafeContent, "personal_information" if PII_PATTERNS.any? { |pattern| text.match?(pattern) } || valid_payment_card_number?(text)
        raise UnsafeContent, "household_fact" if HOUSEHOLD_FACT_PATTERNS.any? { |pattern| text.match?(pattern) }
        raise UnsafeContent, "regional_stereotype" if text.match?(REGIONAL_STEREOTYPE_PATTERN)

        raise UnsafeContent, "unsafe_instruction" if unsafe_instruction?(text)

        true
      end

      def redact_private_details(value)
        redacted = value.to_s.dup
        PII_PATTERNS.each { |pattern| redacted.gsub!(pattern, "[private detail removed]") }
        HOUSEHOLD_FACT_PATTERNS.each { |pattern| redacted.gsub!(pattern, "[private source detail removed]") }
        redacted.gsub!(/(?<!\d)(?:\d[ -]?){13,19}(?!\d)/) do |candidate|
          digits = candidate.gsub(/\D/, "")
          digits.length.between?(13, 19) && luhn_valid?(digits) ? "[private detail removed]" : candidate
        end
        redacted
      end

      private

      def unsafe_instruction?(text)
        UNSAFE_INSTRUCTION_PATTERNS.any? do |pattern|
          text.to_enum(:scan, pattern).any? do
            match = Regexp.last_match
            prefix = text[0...match.begin(0)].to_s.last(80)
            !prefix.match?(/\b(?:do not|don['’]t|never|avoid|must not)\s*\z/i)
          end
        end
      end

      def valid_payment_card_number?(text)
        text.scan(/(?<!\d)(?:\d[ -]?){13,19}(?!\d)/).any? do |candidate|
          digits = candidate.gsub(/\D/, "")
          digits.length.between?(13, 19) && luhn_valid?(digits)
        end
      end

      def luhn_valid?(digits)
        sum = digits.reverse.chars.each_with_index.sum do |character, index|
          value = character.to_i
          next value if index.even?

          doubled = value * 2
          doubled > 9 ? doubled - 9 : doubled
        end
        sum.positive? && (sum % 10).zero?
      end
    end
  end
end
