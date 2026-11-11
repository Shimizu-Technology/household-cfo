module HouseholdFinance
  # Keep the first means, plan and intent disclosures plus recent turns. Safety
  # sentences take priority over filler within an oversized participant message.
  module CareDisclosures
    LIMIT = 12
    ENTRY_BYTES = 400
    FACTS = {
      means: /\b(?:gun|firearm|pistol|rifle|pills?|knife|rope|weapon|overdose)\b/i,
      plan: /\b(?:plan|tonight|tomorrow|today|at \d|going to|about to)\b/i,
      intent: /\b(?:die|kill|hurt|harm|suicid\w*|end my life|not safe)\b/i
    }.freeze
    module_function

    def clip(text)
      text.to_s.byteslice(0, ENTRY_BYTES).to_s.scrub("")
    end

    def content(text)
      text = text.to_s.squish
      return text if text.bytesize <= ENTRY_BYTES

      sentences = text.split(/(?<=[.!?;])\s+|\n/)
      safety, other = sentences.partition { |sentence| FACTS.values.any? { |pattern| sentence.match?(pattern) } }
      # A long unpunctuated sentence can put its safety fact after filler.
      safety = safety.map do |sentence|
        next sentence if sentence.bytesize <= ENTRY_BYTES
        spans = FACTS.values.flat_map do |pattern|
          sentence.to_enum(:scan, pattern).map do
            match = Regexp.last_match
            from = [ match.begin(0) - 60, 0 ].max
            sentence[from, 120]
          end
        end
        spans.uniq.join(" … ")
      end
      clip((safety + other).join(" "))
    end

    def bound_topic(topic)
      topic = topic.to_h.deep_stringify_keys
      entries = Array(topic["disclosures"]).map do |row|
        row = row.to_h.stringify_keys
        { "content" => content(row["content"]), "created_at" => row["created_at"].to_s.first(40) }
      end.reject { |row| row["content"].blank? }.uniq { |row| row["content"] }
      pinned = FACTS.values.filter_map { |pattern| entries.find { |row| row["content"].match?(pattern) } }.uniq
      pinned.unshift(entries.first) if entries.first
      pinned.uniq!
      recent = (entries - pinned).last(LIMIT - pinned.size)
      selected = entries.select { |row| pinned.include?(row) || recent.include?(row) }
      topic = topic.merge("last_question" => clip(topic["last_question"])) if topic.key?("last_question")
      topic.merge("disclosure" => content(topic["disclosure"].presence || selected.first.to_h["content"]),
        "disclosures" => selected)
    end
  end
end
