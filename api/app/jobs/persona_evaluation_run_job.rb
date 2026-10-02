# frozen_string_literal: true

class PersonaEvaluationRunJob < ApplicationJob
  queue_as :default

  def perform(run_id)
    Mia::PersonaRelease::Runner.execute_pending!(run_id)
  end
end
