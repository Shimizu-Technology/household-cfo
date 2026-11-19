# frozen_string_literal: true

require "yaml"

module HouseholdFinance
  class MiaEvalHarness
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
      :metadata,
      :error,
      keyword_init: true
    ) do
      # Every check that failed, in words, for reports.
      def problems
        [
          ("error: #{error}" if error),
          ("missing phrases: #{missing_phrases.inspect}" if missing_phrases.present?),
          ("forbidden phrases: #{forbidden_matches.inspect}" if forbidden_matches.present?),
          ("missing amounts: #{missing_amounts.join('; ')}" if missing_amounts.present?),
          ("unexpected amounts: #{unexpected_amounts.join(', ')}" if unexpected_amounts.present?),
          *Array(rule_violations).map { |violation| "rule #{violation['rule']}: #{violation['detail']}" }
        ].compact
      end
    end

    # A known gap is a case the app can't answer correctly yet. It reports but
    # never fails the run; one that starts passing is listed as a closed gap.
    Result = Struct.new(:case_results, keyword_init: true) do
      def passed?
        failures.empty?
      end

      def failures
        case_results.reject { |result| result.passed || result.known_gap }
      end

      def known_gaps
        case_results.select { |result| result.known_gap && !result.passed }
      end

      def closed_gaps
        case_results.select { |result| result.known_gap && result.passed }
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
      raise ArgumentError, "#{id}: a known_gap needs a gap_reason" if eval_case["known_gap"] && eval_case["gap_reason"].to_s.strip.empty?

      skips = eval_case["skip_rules"] || {}
      raise ArgumentError, "#{id}: skip_rules maps each rule to the reason it does not apply" unless skips.is_a?(Hash)

      skips.each do |rule, reason|
        raise ArgumentError, "#{id}: unknown rule #{rule.inspect}; rules are #{MiaEvalRules::RULES.join(', ')}" unless MiaEvalRules::RULES.include?(rule.to_s)
        raise ArgumentError, "#{id}: skipping #{rule} needs a reason" if reason.to_s.strip.empty?
      end
    end

    # mode :live checks live_expected (when a case defines it) instead of
    # expected_phrases, and adds live_forbidden to forbidden_phrases. Live
    # wording varies, so live expectations are looser than deterministic ones.
    # A runner returns the reply, or { response:, metadata:, ledger: } where ledger
    # is MiaEvalLedger.snapshot of the household the case talked to.
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
      amounts = MiaEvalAmounts.check(eval_case, response, ledger)
      violations = MiaEvalRules.violations(prompt: prompt_for(eval_case), response: response, ledger: ledger, skip: eval_case.fetch("skip_rules", {}).keys.map(&:to_s))

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
      CaseResult.new(
        id: eval_case.fetch("id", "unknown"), prompt: prompt_for(eval_case),
        forbidden_matches: [], missing_amounts: [], unexpected_amounts: [], rule_violations: [], metadata: {}, error: nil,
        known_gap: eval_case["known_gap"] == true, gap_reason: eval_case["gap_reason"], **attributes
      )
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
