# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Attribution is shared by phrases, prose and finite voice presets. A model
    # cannot turn an exact substring inside another speaker's words into hers.
    class CoachSource
      def initialize(coach_name: nil)
        @coach_name = coach_name
      end

      def body(line)
        allowed = [ "coach", "me", "#{@coach_name}" ].reject(&:blank?)
        body = line
        nested = false
        loop do
          label = body.match(/\A\s*(?:["“]([^"”\n]+)["”]|([^:"“\n]+)):\s*/)
          return body unless label

          speaker = label[1] || label[2]
          return body if prose_introduction?(speaker)
          return unless allowed.any? { |name| speaker.strip.casecmp?(name) } || (nested && speaker.strip.casecmp?("note"))

          body = body[label.end(0)..]
          nested = true
        end
      end

      def prose_introduction?(text)
        # Only the final clause before a colon identifies its speaker. An
        # earlier voice instruction cannot turn "Client: I say" into hers.
        text = text.split(/[.!?;—–]/).last.to_s
        text.match?(/\A\s*(?:(?:i|we|she|he|they)(?:\s|['’])|(?:sound|speak|talk|respond|reply)\s+like\b|the coach\s|her (?:phrase|saying|voice|tone|coaching|method|style) (?:is|was)\b|(?:(?:also|please)\s+)*(?:add|use|keep|say)\b)/i)
      end
    end
  end
end
