module HouseholdFinance
  # Bound private context while reserving room for distinct safety facts.
  module CareDisclosures
    LIMIT = 12
    ENTRY_BYTES = 400
    FACTS = {
      means: /\b(?:guns?|firearms?|pistols?|rifles?|pills?|meds|medic(?:ines?|ations?)|knives|knife|ropes?|weapons?|overdose|heights?|bridges?|cliffs?|two lovers point)\b/i,
      plan: /\b(?:plan|tonight|tomorrow|today|at \d|going to|about to)\b/i,
      intent: /\b(?:die|kill|hurt|harm|suicid\w*|end (?:my life|it all)|not safe)\b/i
    }.freeze
    AMBIGUOUS_MEANS = /\b(?:cars?|trucks?|driv(?:e|ing))\b/i
    module_function

    def clip(text, bytes = ENTRY_BYTES)
      text.to_s.byteslice(0, bytes).to_s.scrub("")
    end

    def means?(text)
      text.match?(FACTS[:means]) || text.match?(/#{AMBIGUOUS_MEANS.source}.{0,100}#{FACTS[:intent].source}|#{FACTS[:intent].source}.{0,100}#{AMBIGUOUS_MEANS.source}/i)
    end

    def safety_fact?(text)
      means?(text) || text.match?(FACTS[:intent]) || text.match?(/\b(?:plans?|going to|about to)\b/i)
    end

    def content(text)
      text = text.to_s.squish
      return text if text.bytesize <= ENTRY_BYTES

      # Each category gets space before a long earlier sentence can consume it.
      excerpts = FACTS.filter_map do |kind, pattern|
        matches = text.to_enum(:scan, pattern).map { Regexp.last_match.dup }
        if kind == :means
          matches += text.to_enum(:scan, AMBIGUOUS_MEANS).map { Regexp.last_match.dup }.select do |match|
            text[[ match.begin(0) - 100, 0 ].max..(match.end(0) + 100)].match?(FACTS[:intent])
          end
        end
        matches = matches.uniq { |match| match[0].downcase }.first(3)
        next if matches.empty?
        quota = (126 - (matches.size - 1) * " … ".bytesize) / matches.size
        matches.map do |match|
          before = text[0...match.begin(0)].byteslice(-12, 12).to_s.scrub("")
          clip(before + text[match.begin(0)..], quota)
        end.join(" … ")
      end
      clip(excerpts.empty? ? text : excerpts.join(" … "))
    end

    def bound_topic(topic)
      topic = topic.to_h.deep_stringify_keys
      entries = Array(topic["disclosures"]).map do |row|
        row = row.to_h.stringify_keys
        { "content" => content(row["content"]), "created_at" => row["created_at"].to_s.first(40) }
      end.reject { |row| row["content"].blank? }.uniq { |row| row["content"] }
      safety_start = entries.index { |row| means?(row["content"]) || row["content"].match?(FACTS[:intent]) }
      safety = entries.each_with_index.select do |row, index|
        means?(row["content"]) || row["content"].match?(FACTS[:intent]) ||
          (safety_start && index >= safety_start && row["content"].match?(FACTS[:plan]))
      end.map(&:first)
      # Every distinct safety-bearing turn is pinned, up to the explicit bound.
      # Keep the newest safety facts if that bound is exceeded.
      pinned = (safety.last(8) + entries.first(3)).uniq
      recent = (entries - pinned).last(LIMIT - pinned.size)
      selected = entries.select { |row| pinned.include?(row) || recent.include?(row) }
      topic = topic.merge("last_question" => clip(topic["last_question"])) if topic.key?("last_question")
      topic.merge("disclosure" => content(topic["disclosure"].presence || selected.first.to_h["content"]),
        "disclosures" => selected)
    end
  end
end
