# Live Mia evals against a real model. Never part of the CI gate: it spends OpenRouter
# credit and model wording varies run to run. Only the scheduled workflow
# .github/workflows/mia-live-evals.yml runs it in CI (see LiveRunner::NIGHTLY_OPT_IN).
#
#   RAILS_ENV=test MIA_LIVE_EVALS=1 OPENROUTER_API_KEY=sk-or-... \
#     AI_MODEL=anthropic/claude-sonnet-5.5 bin/rails mia:evals:live
#
# Optional: SET=cfo runs the CFO question set (test/evals/mia_cfo_question_set.yml)
# instead of mia_eval_cases.yml; CASES=id1,id2 runs a subset. Results go to
# tmp/evals/. docs/testing/mia-evals.md explains the checks.
#
# Compare several runs blind, graded by two judge models:
#
#   RAILS_ENV=test OPENROUTER_API_KEY=sk-or-... \
#     REPORTS=tmp/evals/a.json,tmp/evals/b.json bin/rails mia:evals:judge
namespace :mia do
  namespace :evals do
    desc "Run Mia eval cases through the real chat pipeline with a live model (opt-in, costs money)"
    task live: :environment do
      require_relative "mia_evals/live_runner"

      result = MiaEvals::LiveRunner.new.call
      exit(1) unless result
    end

    desc "Blindly grade several live eval reports side by side with two judge models (costs money)"
    task judge: :environment do
      require_relative "mia_evals/judge"

      reports = ENV["REPORTS"].to_s.split(",").map(&:strip).reject(&:blank?)
      exit(1) unless MiaEvals::Judge.new(reports).call
    end
  end
end
