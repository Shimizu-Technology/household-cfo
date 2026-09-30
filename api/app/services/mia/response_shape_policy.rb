# frozen_string_literal: true

module Mia
  class ResponseShapePolicy
    MARKDOWN_PATTERN = /(?:\A|\s)(?:\#{1,6}\s|[-+*]\s|\d+\.\s)|[*_~`]{2}|\[[^\]]+\]\([^)]+\)/.freeze
    SENTENCE_BOUNDARY = /(?<=[.!?])(?:["”’']*)\s+/.freeze

    class << self
      def valid?(content, persona:)
        new(content, persona: persona).valid?
      end
    end

    def initialize(content, persona:)
      @content = content.to_s.squish
      @persona = persona
    end

    def valid?
      return true unless custom_response_shape?

      content.present? &&
        content.length <= shape.fetch("max_characters") &&
        sentence_count.between?(shape.fetch("min_sentences"), shape.fetch("max_sentences")) &&
        (!shape.fetch("plain_text_only") || !content.match?(MARKDOWN_PATTERN))
    end

    private

    attr_reader :content, :persona

    def custom_response_shape?
      persona.respond_to?(:version_id) && persona.version_id.present? && persona.respond_to?(:response_shape)
    end

    def shape
      @shape ||= persona.response_shape
    end

    def sentence_count
      content.split(SENTENCE_BOUNDARY).count(&:present?)
    end
  end
end
