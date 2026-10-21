# frozen_string_literal: true

module Mia
  # The persona's configured assistant name doubles as its label in Coach
  # Studio, so coaches write names like "Mia for Mrs. Mel BOG". Participants
  # should meet the assistant by name ("Mia"), not by the program label.
  #
  # Keep this rule in step with web/src/lib/assistantName.ts.
  module AssistantDisplayName
    LABEL_SEPARATOR = /\s+(?:for|from)\s+|\s+[-–—|·:]\s+|\s*[(\[]/i
    MAX_LENGTH = 32

    module_function

    def short(name)
      full = name.to_s.squish
      first = full.split(LABEL_SEPARATOR, 2).first.to_s.strip
      return full if first.empty? || first.length > MAX_LENGTH

      first
    end
  end
end
