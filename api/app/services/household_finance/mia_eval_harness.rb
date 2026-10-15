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
      :metadata,
      :error,
      keyword_init: true
    )

    Result = Struct.new(:case_results, keyword_init: true) do
      def passed?
        case_results.all?(&:passed)
      end

      def failures
        case_results.reject(&:passed)
      end

      def total_count
        case_results.length
      end

      def passed_count
        case_results.count(&:passed)
      end
    end

    DEFAULT_CASE_PATH = Rails.root.join("test/evals/mia_eval_cases.yml")

    def self.load_cases(path = DEFAULT_CASE_PATH)
      payload = YAML.safe_load_file(path)
      Array(payload.fetch("cases"))
    end

    # mode :live checks live_expected (when a case defines it) instead of
    # expected_phrases, and adds live_forbidden to forbidden_phrases. Live
    # wording varies, so live expectations are looser than deterministic ones.
    def initialize(cases: self.class.load_cases, runner:, mode: :deterministic)
      @cases = cases
      @runner = runner
      @mode = mode.to_sym
    end

    def call
      Result.new(case_results: cases.map { |eval_case| run_case(eval_case.deep_stringify_keys) })
    end

    private

    attr_reader :cases, :runner, :mode

    def run_case(eval_case)
      output = runner.call(eval_case)
      response = response_from(output)
      metadata = metadata_from(output)
      expected_phrases = expected_phrases_for(eval_case)
      forbidden_phrases = forbidden_phrases_for(eval_case)
      missing_phrases = missing_phrases(response, expected_phrases)
      forbidden_matches = matching_phrases(response, forbidden_phrases)

      CaseResult.new(
        id: eval_case.fetch("id"),
        prompt: prompt_for(eval_case),
        response: response,
        passed: response.present? && missing_phrases.empty? && forbidden_matches.empty?,
        missing_phrases: missing_phrases,
        forbidden_matches: forbidden_matches,
        metadata: metadata,
        error: nil
      )
    rescue StandardError => e
      CaseResult.new(
        id: eval_case.fetch("id", "unknown"),
        prompt: prompt_for(eval_case),
        response: "",
        passed: false,
        missing_phrases: expected_phrases_for(eval_case),
        forbidden_matches: [],
        metadata: {},
        error: "#{e.class}: #{e.message}"
      )
    end

    def response_from(output)
      return output.to_s if output.is_a?(String)

      payload = output.respond_to?(:to_h) ? output.to_h : {}
      (payload[:response] || payload["response"]).to_s
    end

    def metadata_from(output)
      return {} if output.is_a?(String)

      payload = output.respond_to?(:to_h) ? output.to_h : {}
      payload[:metadata] || payload["metadata"] || {}
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
