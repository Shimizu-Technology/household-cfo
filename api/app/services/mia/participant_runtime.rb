# frozen_string_literal: true

module Mia
  class ParticipantRuntime
    attr_reader :membership, :cohort, :release, :persona, :capabilities, :source, :exposure

    def initialize(membership:, cohort:, release:, persona:, capabilities:, source:, exposure: nil)
      @membership = membership
      @cohort = cohort
      @release = release
      @persona = persona
      @capabilities = deep_freeze(capabilities.deep_dup)
      @source = source.to_s.freeze
      @exposure = exposure
      freeze
    end

    def release_id = release&.id
    def cohort_id = cohort&.id

    def continuity_id
      return "cohort_release:#{release_id}" if release_id
      return "cohort:#{cohort_id}:#{persona.continuity_id}" if cohort_id

      persona.continuity_id
    end

    def released?
      release.present?
    end

    private

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, entry| deep_freeze(key); deep_freeze(entry) }
      when Array
        value.each { |entry| deep_freeze(entry) }
      end
      value.freeze
    end
  end
end
