# frozen_string_literal: true

module CohortExperience
  # Every message path (including attachments and deterministic early returns)
  # uses the same boundary after model narration and before persistence.
  class AssistantMessageWriter < ::Mia::AssistantMessageWriter
    def build(content:, presentation: {})
      guidance = MiaModuleGuidance.new(participant_runtime&.capabilities)
      super(
        content: guidance.filter(content).to_s.truncate(ChatMessage::MAX_ASSISTANT_CONTENT_LENGTH, omission: "…"),
        presentation: guidance.filter(presentation)
      )
    end
  end
end
