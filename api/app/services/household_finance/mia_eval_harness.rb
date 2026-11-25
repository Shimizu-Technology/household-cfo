# frozen_string_literal: true

require "yaml"

module HouseholdFinance
  class MiaEvalHarness
    # Checks a known gap can name, besides the rules in MiaEvalRules::RULES. A
    # crash or an empty reply is never a gap, and neither is a safety rule
    # (MiaEvalRules::SAFETY_RULES): a reply that breaks one is wrong, not a known gap.
    CHECKS = %w[expected_phrases forbidden_phrases expected_amounts strict_amounts].freeze
    GAP_CHECKS = (CHECKS + MiaEvalRules::RULES - MiaEvalRules::SAFETY_RULES).freeze
    MODES = %w[deterministic live].freeze

    CaseResult = Struct.new(
      :id,
      :prompt,
      :response,
      :passed,
      :missing_phrases,
      :forbidden_matches,
      :missing_amounts,
      :unexpected_amounts,
      :rule_violations,
      :known_gap,
      :gap_reason,
      :gap_checks,
      :metadata,
      :error,
      keyword_init: true
    ) do
      # Every check that failed, in words, for reports.
      def problems
        [
          ("error: #{error}" if error),
          ("no reply" if response.blank? && !error),
          ("missing phrases: #{missing_phrases.inspect}" if missing_phrases.present?),
          ("forbidden phrases: #{forbidden_matches.inspect}" if forbidden_matches.present?),
          ("missing amounts: #{missing_amounts.join('; ')}" if missing_amounts.present?),
          ("unexpected amounts: #{unexpected_amounts.join(', ')}" if unexpected_amounts.present?),
          *Array(rule_violations).map { |violation| "rule #{violation['rule']}: #{violation['detail']}" },
          ("known gap checks now passing: #{closed_gap_checks.join(', ')}" if closed_gap_checks.any?)
        ].compact
      end

      # The names of the checks that failed: CHECKS, rule names, "error" or "no_reply".
      def failed_checks
        [
          ("error" if error),
          ("no_reply" if response.blank? && !error),
          ("expected_phrases" if missing_phrases.present?),
          ("forbidden_phrases" if forbidden_matches.present?),
          ("expected_amounts" if missing_amounts.present?),
          ("strict_amounts" if unexpected_amounts.present?),
          *Array(rule_violations).map { |violation| violation["rule"] }
        ].compact.uniq
      end

      # Failed checks the case's known gap doesn't name. Any of them fails the run.
      def unexpected_failures
        failed_checks - (known_gap ? Array(gap_checks) - MiaEvalRules::SAFETY_RULES : [])
      end

      # Checks the gap names that pass now: that part of the gap has closed.
      def closed_gap_checks
        # A case that raised ran none of its checks, so none of them closed.
        known_gap && !error ? Array(gap_checks) - failed_checks : []
      end
    end

    # A known gap is a case the app can't answer correctly yet. Only the checks
    # it names may fail; anything else fails the run. A gap with a named check
    # that now passes is a closed gap: check the reply, then narrow or remove it.
    Result = Struct.new(:case_results, keyword_init: true) do
      def passed?
        failures.empty?
      end

      def failures
        case_results.select { |result| result.unexpected_failures.any? }
      end

      def known_gaps
        case_results.select { |result| result.known_gap && !result.passed && result.unexpected_failures.empty? }
      end

      def closed_gaps
        case_results.select { |result| result.closed_gap_checks.any? }
      end

      def total_count
        case_results.length
      end

      def passed_count
        case_results.count(&:passed)
      end
    end

    DEFAULT_CASE_PATH = Rails.root.join("test/evals/mia_eval_cases.yml")
    CFO_QUESTION_SET_PATH = Rails.root.join("test/evals/mia_cfo_question_set.yml")
    CASE_SETS = { "default" => DEFAULT_CASE_PATH, "cfo" => CFO_QUESTION_SET_PATH }.freeze

    # A file-level household (for example "cfo") applies to each of its cases.
    def self.load_cases(path = DEFAULT_CASE_PATH)
      payload = YAML.safe_load_file(path)
      household = payload["household"]
      Array(payload.fetch("cases")).map { |eval_case| household ? { "household" => household }.merge(eval_case) : eval_case }
    end

    def self.validate_case!(eval_case)
      id = eval_case["id"] || "unknown"
      raise ArgumentError, "#{id}: gap_reason moved into known_gap: { checks: [...], reason: ... }" if eval_case.key?("gap_reason")
      validate_gap!(id, eval_case["known_gap"]) if eval_case.key?("known_gap")

      skips = eval_case["skip_rules"] || {}
      raise ArgumentError, "#{id}: skip_rules maps each rule to the reason it does not apply" unless skips.is_a?(Hash)

      skips.each do |rule, reason|
        raise ArgumentError, "#{id}: unknown rule #{rule.inspect}; rules are #{MiaEvalRules::RULES.join(', ')}" unless MiaEvalRules::RULES.include?(rule.to_s)
        raise ArgumentError, "#{id}: #{rule} is a safety rule and can't be skipped; fix the reply or the rule instead" if MiaEvalRules::SAFETY_RULES.include?(rule.to_s)
        raise ArgumentError, "#{id}: skipping #{rule} needs a reason" if reason.to_s.strip.empty?
      end
    end

    # known_gap: { checks: [expected_amounts, raw_bank_descriptor], reason: "…", modes: [deterministic] }
    # modes is optional (both by default).
    def self.validate_gap!(id, gap)
      raise ArgumentError, "#{id}: known_gap is { checks: [...], reason: ..., modes: [...] }" unless gap.is_a?(Hash)

      checks = Array(gap["checks"]).map(&:to_s)
      raise ArgumentError, "#{id}: a known_gap names the checks it expects to fail" if checks.empty?
      (checks & MiaEvalRules::SAFETY_RULES).each do |rule|
        raise ArgumentError, "#{id}: #{rule} is a safety rule and can't be a known gap check; fix the reply or the rule instead"
      end
      unknown = checks - GAP_CHECKS
      raise ArgumentError, "#{id}: a known_gap can't name #{unknown.join(', ')}; it can name #{GAP_CHECKS.join(', ')}" if unknown.any?
      raise ArgumentError, "#{id}: a known_gap needs a reason" if gap["reason"].to_s.strip.empty?
      modes = Array(gap.fetch("modes", MODES)).map(&:to_s)
      raise ArgumentError, "#{id}: known_gap modes are #{MODES.join(', ')}" if modes.empty? || (modes - MODES).any?
      raise ArgumentError, "#{id}: known_gap keys are checks, reason and modes" if (gap.keys - %w[checks reason modes]).any?
    end

    # mode :live checks live_expected (when a case defines it) instead of
    # expected_phrases, and adds live_forbidden to forbidden_phrases. Live
    # wording varies, so live expectations are looser than deterministic ones.
    # strict_amounts applies only in deterministic runs: a live reply may add other
    # correct figures. A runner returns the reply, or { response:, replies:,
    # metadata:, ledger: } where ledger is MiaEvalLedger.snapshot of the household
    # the case talked to and replies is [{ prompt:, response: }] for each turn.
    # Phrases and amounts are checked on the final response; the rules on every reply.
    def initialize(cases: self.class.load_cases, runner:, mode: :deterministic)
      @cases = cases.map(&:deep_stringify_keys).each { |eval_case| self.class.validate_case!(eval_case) }
      @runner = runner
      @mode = mode.to_sym
    end

    def call
      Result.new(case_results: cases.map { |eval_case| run_case(eval_case) })
    end

    private

    attr_reader :cases, :runner, :mode

    def run_case(eval_case)
      output = runner.call(eval_case)
      response = response_from(output)
      metadata = metadata_from(output)
      ledger = payload_value(output, :ledger)
      missing_phrases = missing_phrases(response, expected_phrases_for(eval_case))
      forbidden_matches = matching_phrases(response, forbidden_phrases_for(eval_case))
      amounts = MiaEvalAmounts.check(eval_case, response, ledger, strict: mode != :live)
      replies = replies_from(output, eval_case, response)
      violations = rule_violations(eval_case, replies, ledger)
      # Every turn must answer, not only the last one.
      replies.each_with_index do |reply, index|
        next if reply["response"].present? || index == replies.length - 1

        violations << { "rule" => "no_reply", "detail" => "turn #{index + 1} got no reply" }
      end

      case_result(
        eval_case,
        response: response,
        passed: response.present? && [ missing_phrases, forbidden_matches, amounts["missing"], amounts["unexpected"], violations ].all?(&:empty?),
        missing_phrases: missing_phrases,
        forbidden_matches: forbidden_matches,
        missing_amounts: amounts["missing"],
        unexpected_amounts: amounts["unexpected"],
        rule_violations: violations,
        metadata: metadata
      )
    rescue StandardError => e
      case_result(eval_case, response: "", passed: false, missing_phrases: expected_phrases_for(eval_case), error: "#{e.class}: #{e.message}")
    end

    def case_result(eval_case, **attributes)
      gap = eval_case["known_gap"]
      CaseResult.new(
        id: eval_case.fetch("id", "unknown"), prompt: prompt_for(eval_case),
        forbidden_matches: [], missing_amounts: [], unexpected_amounts: [], rule_violations: [], metadata: {}, error: nil,
        known_gap: gap.present? && Array(gap.fetch("modes", MODES)).map(&:to_s).include?(mode.to_s),
        gap_reason: gap && gap["reason"], gap_checks: gap ? Array(gap["checks"]).map(&:to_s) : [], **attributes
      )
    end

    # Each reply is checked with the message it answered, so an income question in
    # turn one is judged by turn one's reply.
    def rule_violations(eval_case, replies, ledger)
      skip = eval_case.fetch("skip_rules", {}).keys.map(&:to_s) - MiaEvalRules::SAFETY_RULES
      replies.each_with_index.flat_map do |reply, index|
        MiaEvalRules.violations(prompt: reply["prompt"], response: reply["response"], ledger: ledger, skip: skip).map do |violation|
          replies.length > 1 ? violation.merge("detail" => "turn #{index + 1}: #{violation['detail']}") : violation
        end
      end
    end

    def replies_from(output, eval_case, response)
      replies = Array(payload_value(output, :replies)).map { |reply| reply.to_h.stringify_keys }
      replies.presence || [ { "prompt" => prompt_for(eval_case), "response" => response } ]
    end

    def response_from(output)
      return output.to_s if output.is_a?(String)

      payload = output.respond_to?(:to_h) ? output.to_h : {}
      (payload[:response] || payload["response"]).to_s
    end

    def metadata_from(output)
      payload_value(output, :metadata) || {}
    end

    def payload_value(output, key)
      return if output.is_a?(String)

      payload = output.respond_to?(:to_h) ? output.to_h : {}
      payload[key] || payload[key.to_s]
    end

    def prompt_for(eval_case)
      messages = Array(eval_case["messages"])
      return messages.last.to_s if messages.any?

      eval_case["prompt"].to_s
    end

    def expected_phrases_for(eval_case)
      return Array(eval_case["live_expected"]) if mode == :live && eval_case.key?("live_expected")

      Array(eval_case["expected_phrases"])
    end

    def forbidden_phrases_for(eval_case)
      phrases = Array(eval_case["forbidden_phrases"])
      mode == :live ? phrases + Array(eval_case["live_forbidden"]) : phrases
    end

    def missing_phrases(response, expected_phrases)
      expected_phrases.reject { |phrase| includes_phrase?(response, phrase) }
    end

    def matching_phrases(response, forbidden_phrases)
      forbidden_phrases.select { |phrase| includes_phrase?(response, phrase) }
    end

    # A phrase may be a list (any one of them counts) or "/regex/" for word
    # boundaries such as /\bpar\b/. Matching is case-insensitive.
    def includes_phrase?(response, phrase)
      return phrase.any? { |option| includes_phrase?(response, option) } if phrase.is_a?(Array)

      text = straight_quotes(phrase)
      body = straight_quotes(response)
      return body.match?(Regexp.new(text[1...-1], Regexp::IGNORECASE)) if text.length > 2 && text.start_with?("/") && text.end_with?("/")

      body.downcase.include?(text.downcase)
    end

    def straight_quotes(value)
      value.to_s.tr("‘’", "''")
    end
  end
end
