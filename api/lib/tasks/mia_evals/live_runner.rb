# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "active_support/testing/time_helpers"
require "action_dispatch/testing/integration"

module MiaEvals
  # Drives every case in test/evals/mia_eval_cases.yml through POST
  # /api/v1/mia/messages with a live OpenRouter model, then writes a JSON result
  # and a readable markdown transcript to tmp/evals/.
  #
  # Runs in the test environment on purpose: the synthetic participant signs in
  # with a test token, and each case runs inside a transaction that is rolled
  # back, so nothing is left behind in the database.
  class LiveRunner
    include ActiveSupport::Testing::TimeHelpers

    PROVIDER_HOST = "openrouter.ai"
    LOG_NOTE_PATTERN = /(Mia|MiaProviderAdmission).*(reject|fallback|invalid|capacity|denied)/i

    # Records each OpenRouter call (title, model, status, tokens, cost) made
    # while a case runs. Only installed inside this rake process.
    module ProviderCallRecorder
      def request(req, body = nil, &block)
        return super unless started? && address.to_s.end_with?(PROVIDER_HOST)

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = super
        LiveRunner.record_provider_call(req, response, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round)
        response
      end
    end

    class << self
      def provider_calls
        @provider_calls ||= []
      end

      def record_provider_call(request, response, elapsed_ms)
        requested = JSON.parse(request.body.to_s) rescue {}
        parsed = JSON.parse(response.body.to_s) rescue {}
        usage = parsed["usage"].to_h
        provider_calls << {
          title: request["X-Title"].to_s.delete_prefix("Household CFO Method").strip.presence || "chat",
          requested_model: requested["model"],
          served_model: parsed["model"],
          status: response.code.to_i,
          elapsed_ms: elapsed_ms,
          finish_reason: parsed.dig("choices", 0, "finish_reason"),
          prompt_tokens: usage["prompt_tokens"].to_i,
          completion_tokens: usage["completion_tokens"].to_i,
          reasoning_tokens: usage.dig("completion_tokens_details", "reasoning_tokens").to_i,
          cost: usage["cost"].to_f,
          error: parsed.dig("error", "message")
        }
      end
    end

    def call
      return false unless preflight

      Net::HTTP.prepend(ProviderCallRecorder) unless Net::HTTP < ProviderCallRecorder
      model = AiModels.text
      cases = selected_cases
      puts "Running #{cases.length} Mia eval cases live with #{model}..."
      started_at = Time.now
      result = HouseholdFinance::MiaEvalHarness.new(cases: cases, runner: method(:run_case), mode: :live).call
      report = build_report(model, cases, result, started_at)
      paths = write_report(report)
      print_summary(report, paths)
      problems = run_problems(result, report)
      problems.each { |problem| warn problem }
      problems.empty?
    end

    # Reasons the report can't be trusted as a comparison of real model replies.
    # Any of them makes the task exit non-zero.
    def run_problems(result, report)
      turns = result.case_results.flat_map { |case_result| Array(case_result.metadata.to_h[:turns]) }
      crashed = result.case_results.count { |case_result| case_result.error.present? || Array(case_result.metadata.to_h[:turns]).empty? }
      failed_turns = turns.count { |turn| turn[:status] != 201 }
      problems = []
      problems << "#{crashed} case(s) raised before finishing; see the report for the error." if crashed.positive?
      problems << "#{failed_turns} turn(s) did not return 201." if failed_turns.positive?
      problems << "#{report[:provider_errors]} model call(s) failed, so some replies are canned fallbacks." if report[:provider_errors].to_i.positive?
      problems
    end

    private

    def preflight
      if ENV["MIA_LIVE_EVALS"] != "1"
        warn "Set MIA_LIVE_EVALS=1 to run live Mia evals. They call a paid model and are never part of CI."
        return false
      end
      if ENV["CI"].present?
        warn "Live Mia evals do not run in CI."
        return false
      end
      if ENV["OPENROUTER_API_KEY"].to_s.strip.blank?
        warn "OPENROUTER_API_KEY is required for live Mia evals."
        return false
      end
      unless Rails.env.test?
        warn "Run with RAILS_ENV=test so the synthetic participant can sign in with a test token and every case rolls back."
        return false
      end
      # Rails merges DATABASE_URL into the test config, so an exported production URL
      # would point this run (and its locks and sequences) at production.
      if ENV["DATABASE_URL"].present?
        warn "Unset DATABASE_URL: live Mia evals only run against the local test database."
        return false
      end
      current_database = ActiveRecord::Base.connection.current_database
      unless ActiveRecord::Base.connection_db_config.env_name == "test" && test_database_name?(current_database)
        warn "Live Mia evals only run against a test database (connected to #{current_database.inspect})."
        return false
      end
      # Test identities are accepted only when no sign-in provider is selected or configured.
      if ENV["AUTH_PROVIDER"].present? || WorkosAuth.configured?
        warn "Unset AUTH_PROVIDER and the WorkOS keys for this run; the synthetic participant signs in with a test identity."
        return false
      end

      true
    end

    def test_database_name?(name)
      # Parallel test workers add a "-N" suffix.
      name.to_s.match?(/_test(?:[_-]|\z)/)
    end

    def selected_cases
      cases = HouseholdFinance::MiaEvalHarness.load_cases
      ids = ENV["CASES"].to_s.split(",").map(&:strip).reject(&:blank?)
      ids.any? ? cases.select { |eval_case| ids.include?(eval_case.fetch("id")) } : cases
    end

    def run_case(eval_case)
      output = nil
      travel_to(HouseholdFinance::MiaEvalHousehold.eval_time) do
        ActiveRecord::Base.transaction do
          user, _household = HouseholdFinance::MiaEvalHousehold.create!(with_history: true)
          session = ActionDispatch::Integration::Session.new(Rails.application)
          turns = Array(eval_case["messages"]).presence || [ eval_case.fetch("prompt") ]
          transcript = turns.map { |message| run_turn(session, user, message) }
          output = { response: transcript.last.fetch(:reply), metadata: { turns: transcript } }
          raise ActiveRecord::Rollback
        end
      end
      print(output && output.dig(:metadata, :turns).all? { |turn| turn[:status] == 201 } ? "." : "E")
      output
    end

    def run_turn(session, user, message)
      self.class.provider_calls.clear
      log = StringIO.new
      capture = ActiveSupport::Logger.new(log)
      Rails.logger.broadcast_to(capture)
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      session.post("/api/v1/mia/messages",
        params: { message: message, year: HouseholdFinance::MiaEvalHousehold::EVAL_YEAR, month: HouseholdFinance::MiaEvalHousehold::EVAL_MONTH },
        headers: { "Authorization" => "Bearer test_token_#{user.id}" },
        as: :json)
      elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
      body = JSON.parse(session.response.body) rescue {}
      {
        message: message,
        reply: body.dig("assistant_message", "content").to_s,
        status: session.response.status,
        latency_ms: elapsed_ms,
        provider_calls: self.class.provider_calls.dup,
        notes: log.string.lines.grep(LOG_NOTE_PATTERN).map(&:strip).uniq.first(5)
      }
    ensure
      Rails.logger.stop_broadcasting_to(capture) if capture
    end

    def build_report(model, cases, result, started_at)
      turns = result.case_results.flat_map { |case_result| Array(case_result.metadata.to_h[:turns]) }
      calls = turns.flat_map { |turn| turn[:provider_calls] }
      replies = result.case_results.map(&:response).reject(&:blank?)
      {
        model: model,
        started_at: started_at.iso8601,
        eval_time: HouseholdFinance::MiaEvalHousehold.eval_time.iso8601,
        passed: result.passed_count,
        total: result.total_count,
        turns: turns.length,
        latency_ms: latency_summary(turns.map { |turn| turn[:latency_ms] }),
        provider_calls: calls.length,
        provider_errors: calls.count { |call| call[:status] != 200 || call[:error].present? },
        truncated: calls.count { |call| call[:finish_reason] == "length" },
        prompt_tokens: calls.sum { |call| call[:prompt_tokens] },
        completion_tokens: calls.sum { |call| call[:completion_tokens] },
        reasoning_tokens: calls.sum { |call| call[:reasoning_tokens] },
        cost_usd: calls.sum { |call| call[:cost] }.round(6),
        cost_per_message_usd: turns.any? ? (calls.sum { |call| call[:cost] } / turns.length).round(6) : 0,
        guardrail_fallback_turns: turns.count { |turn| guardrail_fallback?(turn) },
        chelu_replies: replies.count { |reply| reply.match?(/\bchelu\b/i) },
        replies: replies.length,
        cases: result.case_results.map do |case_result|
          eval_case = cases.find { |candidate| candidate.fetch("id") == case_result.id }
          {
            id: case_result.id,
            passed: case_result.passed,
            missing: case_result.missing_phrases,
            forbidden: case_result.forbidden_matches,
            error: case_result.error,
            live_expectations: eval_case&.key?("live_expected") ? "live" : "deterministic phrases",
            turns: case_result.metadata.to_h[:turns]
          }
        end
      }
    end

    # The model replied, but a Rails guardrail rejected it and Mia used a canned
    # answer instead. Worth comparing across models.
    def guardrail_fallback?(turn)
      Array(turn[:notes]).any? { |note| note.match?(/reject|fallback|denied/i) }
    end

    def latency_summary(values)
      sorted = values.compact.sort
      return {} if sorted.empty?

      { mean: (sorted.sum / sorted.length.to_f).round, p50: sorted[sorted.length / 2], max: sorted.last }
    end

    def write_report(report)
      directory = Rails.root.join("tmp/evals")
      FileUtils.mkdir_p(directory)
      stem = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{report[:model].to_s.gsub(/[^a-z0-9.]+/i, '-')}"
      json_path = directory.join("#{stem}.json")
      markdown_path = directory.join("#{stem}.md")
      File.write(json_path, JSON.pretty_generate(report))
      File.write(markdown_path, markdown(report))
      [ json_path, markdown_path ]
    end

    def markdown(report)
      lines = []
      lines << "# Mia live evals: #{report[:model]}"
      lines << ""
      lines << "- Run: #{report[:started_at]} (household clock frozen at #{report[:eval_time]})"
      lines << "- Passed: #{report[:passed]}/#{report[:total]} cases"
      lines << "- Latency per message (ms): mean #{report.dig(:latency_ms, :mean)}, p50 #{report.dig(:latency_ms, :p50)}, max #{report.dig(:latency_ms, :max)}"
      lines << "- Provider calls: #{report[:provider_calls]} (errors #{report[:provider_errors]}, truncated #{report[:truncated]})"
      lines << "- Tokens: #{report[:prompt_tokens]} in / #{report[:completion_tokens]} out (#{report[:reasoning_tokens]} reasoning)"
      lines << "- Cost: $#{format('%.4f', report[:cost_usd])} total, $#{format('%.5f', report[:cost_per_message_usd])} per message"
      lines << "- Model replies rejected by guardrails (canned answer used): #{report[:guardrail_fallback_turns]}/#{report[:turns]} messages"
      lines << "- \"chelu\" used in #{report[:chelu_replies]}/#{report[:replies]} final replies"
      lines << ""
      lines << "| Case | Result | Checked against | Guardrail fallback | Missing | Forbidden hit |"
      lines << "|---|---|---|---|---|---|"
      report[:cases].each do |eval_case|
        fallback = Array(eval_case[:turns]).any? { |turn| guardrail_fallback?(turn) } ? "yes" : ""
        lines << "| #{eval_case[:id]} | #{eval_case[:passed] ? 'pass' : 'FAIL'} | #{eval_case[:live_expectations]} | #{fallback} | #{table_text(eval_case[:missing])} | #{table_text(eval_case[:forbidden])} |"
      end
      report[:cases].each do |eval_case|
        lines << ""
        lines << "## #{eval_case[:id]} (#{eval_case[:passed] ? 'pass' : 'FAIL'})"
        lines << "Error: #{eval_case[:error]}" if eval_case[:error]
        Array(eval_case[:turns]).each do |turn|
          calls = turn[:provider_calls].map { |call| "#{call[:title]} #{call[:status]} #{call[:elapsed_ms]}ms #{call[:completion_tokens]}tok" }
          lines << ""
          lines << "**Participant:** #{turn[:message]}"
          lines << ""
          lines << "**Mia** (#{turn[:status]}, #{turn[:latency_ms]} ms; #{calls.any? ? calls.join(', ') : 'no model call'}):"
          lines << ""
          lines << turn[:reply].to_s.lines.map { |line| "> #{line.rstrip}" }.join("\n")
          turn[:notes].each { |note| lines << "" << "_log: #{note.truncate(200)}_" }
        end
      end
      lines.join("\n") + "\n"
    end

    def table_text(values)
      Array(values).map { |value| value.is_a?(Array) ? "any of #{value.first(3).join(' / ')}…" : value.to_s }.join("; ").gsub("|", "/")
    end

    def print_summary(report, paths)
      puts
      puts "#{report[:model]}: #{report[:passed]}/#{report[:total]} passed, mean #{report.dig(:latency_ms, :mean)} ms/message, " \
        "$#{format('%.4f', report[:cost_usd])} total ($#{format('%.5f', report[:cost_per_message_usd])}/message), " \
        "#{report[:provider_errors]} provider errors, #{report[:guardrail_fallback_turns]} guardrail fallbacks"
      paths.each { |path| puts "  #{path}" }
    end
  end
end
