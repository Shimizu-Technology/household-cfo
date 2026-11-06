# frozen_string_literal: true

module Mia
  module PersonaSetup
    # Only transcript line labels identify speakers here. Attribution within
    # prose belongs to ProposalGuard, which receives the complete message.
    class CoachSource
      LABEL = /\A\s*([\p{L}][\p{L}\d .’'()#\[\]\/-]{0,35}):\s*/
      ROLES = /\A(?:coach|me|client|participant|speaker|guest)(?:\s*[#\d(\[].*)?\z/i

      def initialize(coach_name: nil, message: "")
        @coach_name = coach_name
        labels = message.lines.filter_map { |line| line.match(LABEL)&.captures&.first }
        @transcript = message.match?(/\btranscript\b/i) ||
          (labels.map(&:downcase).uniq.length >= 2 && labels.any? { |label| label.match?(ROLES) || label.casecmp?(@coach_name.to_s) })
      end

      def body(line)
        label = line.match(LABEL)
        return line unless label && label[1].split.length <= 3

        speaker = label[1].strip
        allowed = [ "coach", "me", @coach_name ].compact.reject(&:blank?)
        own_label = allowed.any? { |name| speaker.casecmp?(name) }
        return line unless @transcript || speaker.match?(ROLES) || own_label
        return unless own_label

        line[label.end(0)..]
      end
    end
  end
end
