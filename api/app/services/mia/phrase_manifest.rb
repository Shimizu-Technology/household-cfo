# frozen_string_literal: true

require "digest"
require "json"

module Mia
  class PhraseManifest
    class << self
      def canonicalize(value)
        case value
        when Hash
          value.stringify_keys.keys.sort.each_with_object({}) { |key, result| result[key] = canonicalize(value.stringify_keys.fetch(key)) }
        when Array
          value.map { |child| canonicalize(child) }
        else
          value
        end
      end

      def entry(link_or_promotion, position:)
        promotion = link_or_promotion.respond_to?(:coach_persona_phrase_promotion) ? link_or_promotion.coach_persona_phrase_promotion : link_or_promotion
        {
          position: position,
          promotion_id: promotion.id,
          proposal_id: promotion.coach_phrase_proposal_id,
          attestation_id: promotion.coach_phrase_attestation_id,
          artifact_id: promotion.artifact_id.to_s,
          artifact_fingerprint: promotion.artifact_fingerprint,
          promotion_digest: promotion.promotion_digest
        }
      end

      def digest_for(entries)
        Digest::SHA256.hexdigest(JSON.generate(Array(entries).map { |entry| canonicalize(entry) }).b)
      end

      def promotions_for_config(persona, config = persona.draft_config)
        phrases = Array(PersonaSchema.normalize(config).to_h["phrases"])
        approved = phrases.each_with_index.filter_map do |phrase, position|
          next unless phrase.is_a?(Hash) && phrase["provenance"] == "approved_source"

          [ phrase, position ]
        end
        promotions = persona.phrase_promotions.where(artifact_id: approved.map { |phrase, _position| phrase["artifact_id"] }).index_by { |promotion| promotion.artifact_id.to_s }
        approved.map do |phrase, position|
          promotion = promotions[phrase["artifact_id"].to_s]
          raise ArgumentError, "Approved-source phrase is missing its promotion record" unless promotion&.integrity_valid? && promotion.artifact == phrase

          [ promotion, position ]
        end
      end
    end
  end
end
