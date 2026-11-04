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

      format_valid? && length_valid?
    end

    def format_valid?
      content.present? && (!custom_response_shape? || !shape.fetch("plain_text_only") || !markdown?)
    end

    def length_valid?
      return true unless custom_response_shape?

      content.length <= shape.fetch("max_characters") &&
        sentence_count.between?(shape.fetch("min_sentences"), shape.fetch("max_sentences"))
    end

    def counts
      { sentences: sentence_count, characters: content.length }.merge(
        shape.slice("min_sentences", "max_sentences", "max_characters").symbolize_keys
      )
    end

    def sentence_count
      # Titles, inline abbreviations, and punctuation inside a quoted clause
      # are not sentence endings. A sentence-ending dollar amount still is.
      content.gsub(HONORIFIC_BEFORE_NAME) { |title| title.delete_suffix(".") }
        .gsub(/\b(?:e\.g|i\.e)\.(?=\s)/i) { |abbreviation| abbreviation.delete(".") }
        .gsub(/[.!?]+(?=["”’']\s+\p{Ll})/, "")
        .gsub(/(?:\.{3,}|…)(?=\s+\p{Ll})/, "")
        .split(SENTENCE_BOUNDARY).count(&:present?)
    end

    private

    attr_reader :content, :raw_content, :persona

    def custom_response_shape?
      persona.respond_to?(:response_shape)
    end

    def shape
      @shape ||= persona.response_shape
    end

    def markdown?
      raw_content.match?(MARKDOWN_BLOCK_PATTERN) || raw_content.match?(MARKDOWN_INLINE_PATTERN)
    end
  end
end
