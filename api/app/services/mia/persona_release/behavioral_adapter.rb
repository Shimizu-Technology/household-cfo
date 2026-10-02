# frozen_string_literal: true

module Mia
  module PersonaRelease
    class BehavioralAdapter
      Response = Data.define(:output, :metadata, :fallback_only)

      def kind
        raise NotImplementedError
      end

      def call(evaluation_case:, persona:, candidate:)
        raise NotImplementedError
      end
    end
  end
end
