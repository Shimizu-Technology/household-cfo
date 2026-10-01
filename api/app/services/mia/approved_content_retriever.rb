# frozen_string_literal: true

require "set"

module Mia
  class ApprovedContentRetriever
    MAX_ITEMS = 6
    MAX_BYTES = 6_000
    TOKEN_PATTERN = /[[:alnum:]]{3,}/

    def initialize(persona:, query:, pack_versions: nil)
      @persona = persona
      @query = query.to_s
      @pack_versions = pack_versions
    end

    def call
      candidates = content_pack_links.flat_map { |link| candidates_for_link(link) }

      selected = []
      used_bytes = 0
      seen_digests = Set.new
      candidates.sort_by { |entry| entry.fetch(:sort_key) }.each do |entry|
        item = entry.fetch(:item_version)
        next if seen_digests.include?(item.content_digest)
        break if selected.length >= MAX_ITEMS

        remaining = MAX_BYTES - used_bytes
        break if remaining <= 0

        excerpt = utf8_prefix(item.content, remaining)
        next if excerpt.blank?

        selected << entry.except(:sort_key).merge(content: excerpt, rank: selected.length + 1)
        seen_digests << item.content_digest
        used_bytes += excerpt.bytesize
      end
      selected
    end

    private

    attr_reader :persona, :query, :pack_versions

    Link = Data.define(:coach_content_pack_version, :position)

    def content_pack_links
      if pack_versions
        return Array(pack_versions).each_with_index.map { |version, position| Link.new(coach_content_pack_version: version, position: position) }
      end
      return [] unless persona.respond_to?(:version) && persona.version

      persona.version.content_pack_links
        .includes(coach_content_pack_version: { entries: { coach_content_item_version: :coach_content_item } })
        .order(:position)
    end

    def candidates_for_link(link)
      pack = link.coach_content_pack_version
      pack.entries.sort_by(&:position).map do |entry|
        item = entry.coach_content_item_version
        score, terms = match_score(item)
        {
          item_version: item,
          pack_version: pack,
          reason: terms.any? ? "Matched: #{terms.first(4).join(', ')}" : "Approved #{pack.pack_kind.humanize.downcase} guidance",
          sort_key: [ pack.scope == "coach" ? 0 : 1, -score, link.position, entry.position, item.id ]
        }
      end
    end

    def match_score(item)
      query_terms = tokens(query)
      item_terms = tokens("#{item.title} #{item.content}")
      matches = query_terms & item_terms
      title_matches = query_terms & tokens(item.title)
      [ matches.length + (title_matches.length * 2), matches.sort ]
    end

    def tokens(value)
      value.to_s.downcase.scan(TOKEN_PATTERN).uniq
    end

    def utf8_prefix(value, max_bytes)
      return value if value.bytesize <= max_bytes

      value.byteslice(0, max_bytes).to_s.force_encoding(Encoding::UTF_8).scrub.sub(/\s+\S*\z/, "").strip
    end
  end
end
