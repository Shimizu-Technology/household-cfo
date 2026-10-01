# frozen_string_literal: true

module Mia
  class PhraseArtifactAudience
    class << self
      def scope(artifacts, participant_id:)
        Array(artifacts).filter_map do |artifact|
          entry = artifact.respond_to?(:stringify_keys) ? artifact.stringify_keys : nil
          next unless entry

          case entry["provenance"]
          when "coach_authored"
            entry
          when "participant_supplied"
            entry if same_participant?(entry["source_user_id"], participant_id)
          end
        end
      end

      private

      def same_participant?(source_user_id, participant_id)
        source_id = Integer(source_user_id, exception: false)
        audience_id = Integer(participant_id, exception: false)
        source_id.present? && audience_id.present? && source_id == audience_id
      end
    end
  end
end
