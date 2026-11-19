# frozen_string_literal: true

module HouseholdFinance
  # Rules every Mia eval reply must keep, in deterministic and live runs alike.
  # A case can skip a rule only with a reason: skip_rules: { rule_name: "why" }.
  # docs/testing/mia-evals.md explains each rule.
  module MiaEvalRules
    RULES = %w[protected_cut one_month_saving raw_bank_descriptor income_answered_with_spending].freeze

    SENTENCE = /(?<=[.!?])\s+|\n+/
    # A suggestion to spend less on something. The text after the verb is what would be cut.
    CUT = /\b(?:cut(?:s|ting)?(?:\s+back)?(?:\s+on)?|trim(?:s|ming)?|reduc(?:e|es|ing)|halv(?:e|es|ing)|scal(?:e|ing)\s+back(?:\s+on)?|spend(?:ing)?\s+(?:half|less)(?:\s+as\s+much)?(?:\s+(?:at|on))?|stop(?:ping)?\s+(?:paying|sending|buying|going)|drop(?:ping)?|cancel(?:s|ling|ing)?)\b/i
    # "never suggest cutting …", "I won't tell you to cut …".
    NEGATED = /\b(?:never|not|no|don['’]t|do\s+not|doesn['’]t|won['’]t|wouldn['’]t|shouldn['’]t|can['’]t|cannot|without|avoid|instead\s+of|rather\s+than)\b(?:\W+\w+){0,4}\W*\z/i
    # Where the thing being cut ends: "cut back on Jamaican Grill, not rent". Commas don't end it, so a list stays whole.
    CUT_OBJECT_END = /[;:—–()]|\b(?:but|not|instead|rather|while|so|except|keep|keeping|protect|protecting)\b/i
    MONTHLY = %r{\b(?:a|per|each|every)\s+month\b|\bmonthly\b|/\s?mo\b}i
    SAVING = /\b(?:sav(?:e|es|ed|ing|ings)|free(?:s|d)?|cut(?:s|ting)?|half|less|trim(?:ming)?|reduc\w*|redirect\w*)\b/i
    ONE_OFF = /\b(?:one[- ]time|one[- ]off|only\s+once|just\s+once|happened\s+once|(?:isn['’]t|is\s+not|wasn['’]t|was\s+not|not)\s+(?:a\s+)?(?:monthly|every\s+month|regular|recurring|repeat))\b/i
    # The bank's wording around a store name. Coaching labels drop it (SpendingPatterns::MerchantName).
    RAW_DESCRIPTORS = [
      /\b(?:recurring\s+payment|purchase(?:\s+with\s+cash\s+back\s+\$[\d.,]+)?|money\s+transfer|non-wf\s+atm\s+withdrawal)\s+authorized\s+on\b/i,
      /\b[A-Z]\*\s*[·•*xX]{2,}\d{2,}/,
      /\bcard\s+(?!20\d{2}\b)\d{4}\b/i,
      /\bref\s*#\s*[a-z0-9]{6,}/i
    ].freeze
    # Fallback until HouseholdFinance::MiaIncomeAnswer (#311) is on main.
    INCOME_QUESTION = /\bhow much\b[^?.!]{0,30}\b(?:came|come|comes|coming)\s+in\b|\bhow much\b[^?.!]{0,30}\b(?:did|do|does|have|will)\s+(?:we|i|you)\s+(?:earn|make|bring\s+in|get\s+paid)\b/i
    NOT_INCOME = /\b(?:if|would|could|should|afford|add|set|change|update|save|record|log|spent|spend|spending)\b/i
    SPENDING_CLAIM = /\byou(?:['’]ve|\s+have)?\s+spent\b|\bspent\s+(?:about\s+|around\s+)?\$|\b(?:purchases?|spending)\b[^.!?]{0,40}\btotal(?:s|ed|ing)?\b|\btotal(?:s|ed|ing)?\b[^.!?]{0,20}\b(?:spending|purchases?)\b|\b(?:flexible|confirmed)\s+spending\b/i

    module_function

    # Returns [{ "rule" => name, "detail" => text }]. ledger is a MiaEvalLedger snapshot, or nil.
    def violations(prompt:, response:, ledger: nil, skip: [])
      ledger = ledger.to_h.stringify_keys
      found = []
      sentences = response.to_s.split(SENTENCE).map(&:squish).compact_blank
      found.concat(protected_cuts(sentences, ledger)) unless skip.include?("protected_cut")
      found.concat(one_month_savings(sentences, ledger)) unless skip.include?("one_month_saving")
      found.concat(raw_descriptors(response)) unless skip.include?("raw_bank_descriptor")
      found.concat(income_spending(prompt, response, ledger)) unless skip.include?("income_answered_with_spending")
      found
    end

    def income_question?(prompt)
      return MiaIncomeAnswer.question?(prompt) if HouseholdFinance.const_defined?(:MiaIncomeAnswer)

      text = prompt.to_s.squish
      text.match?(INCOME_QUESTION) && !text.match?(NOT_INCOME)
    end

    def protected_cuts(sentences, ledger)
      names = Array(ledger["protected_names"])
      sentences.filter_map do |sentence|
        target = cut_targets(sentence).find do |object|
          object.match?(SpendingPatterns::Analyzer::PROTECTED_CATEGORY) || names.any? { |name| names_in?(object, name) }
        end
        violation("protected_cut", sentence) if target
      end
    end

    def cut_targets(sentence)
      sentence.to_enum(:scan, CUT).filter_map do
        match = Regexp.last_match
        next if match.pre_match.match?(NEGATED)

        match.post_match.first(90).split(CUT_OBJECT_END, 2).first.to_s
      end
    end

    def one_month_savings(sentences, ledger)
      merchants = Array(ledger["one_month_merchants"])
      sentences.filter_map do |sentence|
        next unless sentence.match?(MONTHLY) && sentence.match?(SAVING) && !sentence.match?(ONE_OFF)

        merchant = merchants.find { |name| names_in?(sentence, name) }
        violation("one_month_saving", "#{merchant}: #{sentence}") if merchant
      end
    end

    def raw_descriptors(response)
      RAW_DESCRIPTORS.filter_map do |pattern|
        match = response.to_s.match(pattern)
        violation("raw_bank_descriptor", match[0]) if match
      end
    end

    def income_spending(prompt, response, ledger)
      return [] unless income_question?(prompt)

      found = []
      claim = response.to_s.match(SPENDING_CLAIM)
      found << violation("income_answered_with_spending", claim[0]) if claim
      # The live runner checks replies after its frozen clock is released, so read "last month" from the snapshot's day.
      month = MiaMonthAnswer.question_date(prompt, today: ledger["today"] ? Date.iso8601(ledger["today"]) : Date.current)
      spent = month && ledger.dig("month_spending", month.strftime("%Y-%m"))
      if spent.to_i.positive? && MiaEvalAmounts.mentions?(response, spent)
        found << violation("income_answered_with_spending", "states #{month.strftime('%B %Y')} spending of #{MiaEvalAmounts.format(spent)}")
      end
      found
    end

    def names_in?(text, name)
      label = name.to_s.squish
      label.length >= 3 && text.match?(/(?<![[:alnum:]])#{Regexp.escape(label)}(?![[:alnum:]])/i)
    end

    def violation(rule, detail) = { "rule" => rule, "detail" => detail.to_s.truncate(240) }
  end
end
