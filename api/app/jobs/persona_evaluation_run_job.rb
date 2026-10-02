# frozen_string_literal: true

class PersonaEvaluationRunJob < ApplicationJob
  queue_as :default

  def perform(run_id, lease_token)
    Mia::PersonaRelease::Runner.execute_pending!(run_id, lease_token: lease_token)
  end
end
