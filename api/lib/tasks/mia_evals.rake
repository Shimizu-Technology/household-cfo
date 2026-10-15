# Live Mia evals against a real model. Never part of CI: it spends OpenRouter
# credit and model wording varies run to run.
#
#   RAILS_ENV=test MIA_LIVE_EVALS=1 OPENROUTER_API_KEY=sk-or-... \
#     AI_MODEL=anthropic/claude-sonnet-5.5 bin/rails mia:evals:live
#
# Optional: CASES=id1,id2 to run a subset. Results go to tmp/evals/.
namespace :mia do
  namespace :evals do
    desc "Run Mia eval cases through the real chat pipeline with a live model (opt-in, costs money)"
    task live: :environment do
      require_relative "mia_evals/live_runner"

      result = MiaEvals::LiveRunner.new.call
      exit(1) unless result
    end
  end
end
