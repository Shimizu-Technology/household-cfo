# frozen_string_literal: true

require "set"

module Mia
  class ApprovedContentRetriever
    MAX_ITEMS = 6
    MAX_BYTES = 6_000
    TOKEN_PATTERN = /[[:alnum:]]{3,}/
    STOP_WORDS = Set.new(%w[
      about after again against all also and any are aren because been before being below between both but
      can cannot could couldn did does doesn doing don down during each either even ever every few for from
      further had hadn has hasn have haven having here how into isn its itself just make made many may might
      more most much must need neither never nor not now off once only other our ours ourselves out over own
      perhaps per plan planning question questions really same shall should shouldn some such than that the
      their theirs them themselves then there these they thing things this those through too under until use
      used using very via want was wasn were weren what when where which while who whom why will with won
      would wouldn you your yours yourself
      yourselves answer coach coaching content decision decisions explain guidance help household participant
      participants
    ]).freeze

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
        next if entry.fetch(:score).zero? && !item.always_on?
        next if seen_digests.include?(item.content_digest)
        break if selected.length >= MAX_ITEMS

        remaining = MAX_BYTES - used_bytes
        break if remaining <= 0

        excerpt = utf8_prefix(item.content, remaining)
        next if excerpt.blank?

        selected << entry.except(:sort_key, :score).merge(content: excerpt, rank: selected.length + 1)
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
        return Array(pack_versions).select(&:manifest_valid?).each_with_index.map { |version, position| Link.new(coach_content_pack_version: version, position: position) }
      end
      return [] unless persona.respond_to?(:version) && persona.version
      return [] unless persona.version.content_manifest_valid?

      persona.version.content_pack_links
        .includes(coach_content_pack_version: { entries: { coach_content_item_version: :coach_content_item } })
        .order(:position)
    end

    def candidates_for_link(link)
      pack = link.coach_content_pack_version
      return [] unless pack.manifest_valid?

      pack.entries.sort_by(&:position).map do |entry|
        item = entry.coach_content_item_version
        score, terms = match_score(item)
        {
          item_version: item,
          pack_version: pack,
          reason: terms.any? ? "Context supplied for: #{terms.first(4).join(', ')}" : "Always-on coach-approved context",
          score: score,
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
      value.to_s.downcase.scan(TOKEN_PATTERN).reject { |token| STOP_WORDS.include?(token) }.uniq
    end

    def utf8_prefix(value, max_bytes)
      return value if value.bytesize <= max_bytes

      value.byteslice(0, max_bytes).to_s.force_encoding(Encoding::UTF_8).scrub.sub(/\s+\S*\z/, "").strip
    end
  end
end
