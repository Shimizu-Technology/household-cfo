# frozen_string_literal: true

module Mia
  class ResponseShapePolicy
    MARKDOWN_BLOCK_PATTERN = /(?:\A|\n)[ \t]{0,3}(?:\#{1,6}[ \t]+|[-+*][ \t]+|\d+\.[ \t]+)/.freeze
    MARKDOWN_INLINE_PATTERN = /[*_~`]{2}|\[[^\]]+\]\([^)]+\)/.freeze
    SENTENCE_BOUNDARY = /(?<=[.!?])(?:["”’']*)\s+/.freeze
    HONORIFIC_BEFORE_NAME = /\b(?:Mr|Mrs|Ms|Mx|Dr|Prof)\.(?=\s+\p{Lu})/.freeze

    class << self
      def valid?(content, persona:)
        new(content, persona: persona).valid?
      end
    end

    def initialize(content, persona:)
      @raw_content = content.to_s
      @content = raw_content.squish
      @persona = persona
    end

    def valid?
      return true unless custom_response_shape?

      content.present? &&
        content.length <= shape.fetch("max_characters") &&
        sentence_count.between?(shape.fetch("min_sentences"), shape.fetch("max_sentences")) &&
        (!shape.fetch("plain_text_only") || !markdown?)
    end

    private

    attr_reader :content, :raw_content, :persona

    def custom_response_shape?
      persona.respond_to?(:response_shape)
    end

    def shape
      @shape ||= persona.response_shape
    end

    def sentence_count
      # A coach title such as "Mrs. Mel" is part of the same sentence.
      content.gsub(HONORIFIC_BEFORE_NAME) { |title| title.delete_suffix(".") }
        .split(SENTENCE_BOUNDARY).count(&:present?)
    end

    def markdown?
      raw_content.match?(MARKDOWN_BLOCK_PATTERN) || raw_content.match?(MARKDOWN_INLINE_PATTERN)
    end
  end
end
