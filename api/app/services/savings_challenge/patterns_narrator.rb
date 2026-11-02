module SavingsChallenge
  # Keep challenge boundaries while sharing the exact-figure pattern contract.
  class PatternsNarrator < Narrator
    include SpendingPatterns::Narration
  end
end
