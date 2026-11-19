# frozen_string_literal: true

module HouseholdFinance
  # Dollar figures in a Mia reply, checked against a case's expected_amounts
  # (and, with strict_amounts, allowed_amounts). An amount is cents (4500), a
  # dollar string ("$1,234.56") or a ledger form read from the eval household
  # ({ ledger: month_spending, month: "2026-07" }); see MiaEvalLedger.
  module MiaEvalAmounts
    MONEY = /(?<![\w.$])-?\$\s?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{2}))?(?!\d)/

    module_function

    # [{ cents:, whole: }] for each "$…" figure. whole means no cents were written.
    def amounts(text)
      text.to_s.to_enum(:scan, MONEY).map do
        match = Regexp.last_match
        { cents: match[1].delete(",").to_i * 100 + match[2].to_i, whole: match[2].nil? }
      end
    end

    # A whole-dollar figure matches its rounded value, as the app's currency
    # formatting writes it. The sign is in the words ("short by $1,780"), so
    # figures compare by size.
    def matches?(found, cents)
      expected = cents.to_i.abs
      found[:cents] == expected || (found[:whole] && found[:cents] == (expected / 100.0).round * 100)
    end

    def mentions?(text, cents) = amounts(text).any? { |found| matches?(found, cents) }

    def cents(value)
      case value
      when Integer then value
      when nil then 0
      else
        match = value.to_s.squish.match(/\A-?\$?\s?(\d{1,3}(?:,\d{3})+|\d+)(?:\.(\d{2}))?\z/)
        raise ArgumentError, "#{value.inspect} is not an amount; use cents or \"$1,234.56\"" unless match

        (match[1].delete(",").to_i * 100 + match[2].to_i) * (value.to_s.strip.start_with?("-") ? -1 : 1)
      end
    end

    def format(cents)
      ActiveSupport::NumberHelper.number_to_currency(cents.to_i.abs / 100.0, precision: cents.to_i.modulo(100).zero? ? 0 : 2)
    end

    # { "missing" => [labels], "unexpected" => [labels] }. strict: false ignores
    # strict_amounts (live runs, where a reply may add other correct figures).
    def check(eval_case, response, ledger, strict: true)
      expected = Array(eval_case["expected_amounts"]).map { |spec| resolve(spec, ledger) }
      missing = expected.filter_map do |row|
        row[:label] if row[:cents].nil? || !mentions?(response, row[:cents])
      end
      unexpected = []
      if strict && eval_case["strict_amounts"]
        allowed = expected + Array(eval_case["allowed_amounts"]).map { |spec| resolve(spec, ledger) }
        unexpected = amounts(response).reject { |found| allowed.any? { |row| row[:cents] && matches?(found, row[:cents]) } }
          .map { |found| format(found[:cents]) }.uniq
      end
      { "missing" => missing, "unexpected" => unexpected }
    end

    def resolve(spec, ledger)
      return { cents: cents(spec), label: format(cents(spec)) } unless spec.is_a?(Hash)

      spec = spec.stringify_keys
      name = spec.except("ledger").map { |key, value| "#{key} #{value}" }.unshift(spec["ledger"]).join(" ")
      value = ledger.to_h.stringify_keys.dig("amounts", MiaEvalLedger.spec_key(spec))
      return { cents: nil, label: "#{name} (no ledger from the runner)" } if value.nil?
      return { cents: nil, label: "#{name} (#{value['unavailable']})" } if value.is_a?(Hash)

      { cents: value, label: "#{name} (#{format(value)})" }
    end
  end
end
