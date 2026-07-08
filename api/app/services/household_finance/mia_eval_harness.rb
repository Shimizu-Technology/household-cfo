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

    def initialize(cases: self.class.load_cases, runner:)
      @cases = cases
      @runner = runner
    end

    def call
      Result.new(case_results: cases.map { |eval_case| run_case(eval_case.deep_stringify_keys) })
    end

    private

    attr_reader :cases, :runner

    def run_case(eval_case)
      output = runner.call(eval_case)
      response = response_from(output)
      metadata = metadata_from(output)
      expected_phrases = Array(eval_case["expected_phrases"])
      forbidden_phrases = Array(eval_case["forbidden_phrases"])
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
        missing_phrases: Array(eval_case["expected_phrases"]),
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

    def missing_phrases(response, expected_phrases)
      expected_phrases.reject { |phrase| includes_phrase?(response, phrase) }
    end

    def matching_phrases(response, forbidden_phrases)
      forbidden_phrases.select { |phrase| includes_phrase?(response, phrase) }
    end

    def includes_phrase?(response, phrase)
      response.to_s.downcase.include?(phrase.to_s.downcase)
    end
  end
end
