# frozen_string_literal: true

module Mia
  class RuntimePersona
    FALLBACKS = {
      "low_signal_test" => "Your test came through. Ask me a real money question like “Can I leave my job?” or “Should I pay debt first?” and I’ll use your Household CFO context.",
      "low_signal_greeting" => "I’m ready. Tell me the money decision you want to work through, or choose one of the quick questions. We’ll use your real household numbers and make one clear CFO call at a time.",
      "spending" => "That purse isn’t in the cards right now. If the purchase is not protecting the roof, food, runway, or the dream, it does not get to jump the line today. Put it on a 30-day list, then fund it from true surplus instead of emergency money.",
      "spending_check" => "Pause for one minute. If this purchase is not already funded after bills, debt minimums, groceries, and emergency runway, it waits. Put a dollar amount and a date on it so the want stays dignified without stealing from the household baseline.",
      "crisis" => "I’m really glad you said that out loud. If you might hurt yourself or you feel unsafe, call or text 988 now, call 911, or get next to a trusted person immediately. We can come back to the money plan after you are safe; tonight’s next move is not budgeting, it is getting support.",
      "zero_income_next_step" => "Add your real numbers first so I can coach from the household picture, not a guess.",
      "default_next_step" => "Your next move is one clear choice that protects the household baseline."
    }.freeze
    UNCERTAINTY_LINE = "Based on what I can see, I do not have enough approved data to answer that as a fact yet.".freeze

    attr_reader :version

    class << self
      def for_preview(config:, persona_id:, draft_revision:)
        new(
          nil,
          config: config,
          identifier: "coach_persona_#{persona_id}_draft_#{draft_revision}",
          persona_id: persona_id
        )
      end

      def for_participant(version:, user:, cohort_membership:)
        persisted_version = CoachPersonaVersion.includes(:coach_persona).find_by(id: version&.id)
        return new(version) unless persisted_version

        runtime = new(persisted_version)
        participant_id = verified_participant_id(
          version: persisted_version,
          user: user,
          cohort_membership: cohort_membership
        )
        runtime.instance_variable_set(:@participant_id, participant_id) if participant_id
        runtime
      end

      def for_release(version:, user:, cohort_membership:, release:)
        persisted_version = CoachPersonaVersion.includes(:coach_persona).find_by(id: version&.id)
        raise ActiveRecord::RecordNotFound, "release persona version is unavailable" unless persisted_version

        membership = CohortMembership.find_by(
          id: cohort_membership&.id,
          user_id: user&.id,
          cohort_id: release&.cohort_id,
          role: "participant"
        )
        unless membership && release.coach_persona_version_id == persisted_version.id &&
            release.coach_persona_id == persisted_version.coach_persona_id
          raise ActiveRecord::RecordNotFound, "release persona does not match the participant runtime"
        end

        new(persisted_version).tap { |runtime| runtime.instance_variable_set(:@participant_id, user.id) }
      end

      private

      def verified_participant_id(version:, user:, cohort_membership:)
        persisted_user = User.find_by(id: user&.id, role: "participant", invitation_status: "accepted")
        return unless persisted_user

        membership = CohortMembership.includes(cohort: :cohort_persona_assignment).find_by(
          id: cohort_membership&.id,
          user_id: persisted_user.id,
          role: "participant"
        )
        assignment = membership&.cohort&.cohort_persona_assignment
        return unless assignment&.coach_persona_id == version.coach_persona_id
        return unless assignment.coach_persona_version_id == version.id
        return unless version.coach_persona.current_published_version_id == version.id

        persisted_user.id
      end
    end

    def initialize(version, config: nil, identifier: nil, persona_id: nil)
      @version = version
      raise ArgumentError, "published persona config must come from its sealed version" if version && config

      runtime_config = version ? PersonaRuntimeCompatibility.call(version) : config
      @config = PersonaSchema.validate!(runtime_config)
      @identifier = identifier
      @persona_id = persona_id
    end

    def id
      @identifier || "coach_persona_#{persona_id}_version_#{version.version_number}"
    end

    def persona_id
      @persona_id || version.coach_persona_id
    end

    def version_id
      version&.id
    end

    def continuity_id
      return "coach_persona_version:#{version_id}" if version_id

      "runtime_persona:#{id}"
    end

    def name
      identity.fetch("assistant_name")
    end

    def role
      identity.fetch("assistant_relationship")
    end

    def voice_summary
      [ voice.fetch("tone_traits").to_sentence, voice.fetch("energy") ].compact_blank.join(". ")
    end

    def disclaimer
      "#{name} is an AI coaching assistant built from #{identity.fetch('human_coach_name')}'s approved guidance. " \
        "#{name} does not impersonate or replace that coach and does not replace legal, tax, investment, accounting, therapeutic, or financial advice."
    end

    def system_prompt
      PersonaPromptBuilder.call(scoped_config)
    end

    def fallback_response(key)
      FALLBACKS.fetch(key.to_s)
    end

    def uncertainty_line
      UNCERTAINTY_LINE
    end

    def cultural_phrases
      scoped_config.fetch("phrases")
    end

    def all_cultural_phrases
      config.fetch("phrases")
    end

    def response_shape
      config.fetch("response_shape")
    end

    private

    attr_reader :config, :participant_id

    def scoped_config
      @scoped_config ||= config.merge(
        "phrases" => PhraseArtifactAudience.scope(config.fetch("phrases"), participant_id: participant_id)
      )
    end

    def identity
      config.fetch("identity")
    end

    def voice
      config.fetch("voice")
    end
  end
end
