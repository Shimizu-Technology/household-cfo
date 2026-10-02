# frozen_string_literal: true

module Mia
  module PersonaRelease
    class HybridBehavioralAdapter < BehavioralAdapter
      def initialize(deterministic: DeterministicAdapter.new, live: LiveBehavioralAdapter.new)
        @deterministic = deterministic
        @live = live
      end

      def kind
        "deterministic_required_live_custom_v1"
      end

      def call(evaluation_case:, persona:, candidate:)
        adapter = evaluation_case.case_kind == "system" ? deterministic : live
        adapter.call(evaluation_case:, persona:, candidate:)
      end

      private

      attr_reader :deterministic, :live
    end
  end
end
