module Mia
  class CrisisBoundary
    FIRST_PERSON_SELF_HARM_INTENT_SOURCE = "(?:i(?:['’]m|\\s+am)\\s+(?:going\\s+to|about\\s+to|planning\\s+to|thinking\\s+(?:about|of))|i\\s+(?:want|plan|intend)\\s+to)".freeze
    # The phrase must end its clause, so "done with life insurance" or "point of
    # living paycheck to paycheck" stays money talk.
    PHRASE_END = "(?=\\s*(?:[.!?,;…]|\\z|\\b(?:anyway|tbh|lol|honestly|fr|man)\\b))"
    # Stricter end: the sentence itself ends ("…wake up." not "…wake up, it's Monday").
    SENTENCE_END = "(?=\\s*(?:[.!?…]|\\z|\\b(?:tbh|honestly|fr)\\b))"
    PATTERNS = [
      /\b(?:kill(?:ing)? myself|end(?:ing)? my life|tak(?:e|ing) my own life|end it all|want to die|suicidal|suicide|hurt(?:ing)? myself|harm(?:ing)? myself|self[-\s]?harm)\b/i,
      /\b#{FIRST_PERSON_SELF_HARM_INTENT_SOURCE}\s+(?:shoot(?:ing)?|hang(?:ing)?|drown(?:ing)?|stab(?:bing)?|poison(?:ing)?|suffocat(?:e|ing))\s+myself\b/i,
      /\b#{FIRST_PERSON_SELF_HARM_INTENT_SOURCE}\s+overdos(?:e|ing)\b/i,
      /\bi\s+wish\s+i\s+(?:were|was)\s+(?:dead|not alive)\b|\bi(?:['’]d|\s+would)\s+rather\s+be\s+dead\b/i,
      /\b(?:don['’]?t|do not) want to (?:be alive|live(?: anymore)?|keep living)\b/i,
      /\b(?:don['’]?t|do not) think I can (?:keep living|go on)\b/i,
      /\b(?:can['’]?t|cannot) go on(?:[.!?,;:]|\z|\s+(?:anymore|living|like this|with (?:my )?life|with this anymore)\b)/i,
      /\b(?:can['’]?t|cannot) go on\s+with\s+(?:this|the|my)?\s*(?:debt|bills?|money stress)\b.*\banymore\b/i,
      /\b(?:everyone|everybody|they|my (?:family|kids|children|wife|husband|partner)|the kids)(?:['’]s|['’]d|['’]re|\s+would|\s+will|\s+is|\s+are|\s+r)?(?:\s+all)?\s+(?:be\s+)?better off (?:without me|if i (?:was|were) gone|if i (?:wasn['’]?t|weren['’]?t) here)(?=\s*(?:[.!?,;…]|\z|\b(?:anyway|tbh|lol|honestly|fr)\b))/i,
      # Crisis when the sentence ends there; with more after a comma it gets the
      # gentler check instead (see HOPELESS_PATTERNS).
      /\b(?:don['’]?t|dont|do not)\s+(?:wanna|want to)\s+be (?:here|alive) any\s?more(?=\s*(?:[.!?…]|\z|\b(?:tbh|lol|honestly|fr)\b))/i,
      /\b(?:i['’]m|im|i am)\s+(?:so\s+)?done (?:with (?:life|living)|living)#{PHRASE_END}/i,
      /\b(?:what['’]?s|whats|what is) (?:even )?the point (?:of|in) (?:living|being alive|life)#{PHRASE_END}/i,
      /\b(?:don['’]?t|dont|do not)\s+(?:wanna|want to)\s+wake up(?:\s+(?:tomorrow|again|anymore))?#{SENTENCE_END}/i,
      /\bi\s+wish\s+i\s+(?:wasn['’]?t|wasnt|weren['’]?t|was not|were not)\s+(?:here|alive|born)#{SENTENCE_END}/i,
      /\b(?:no|see no|don['’]?t see (?:the|any)|dont see (?:the|any)) point in (?:living|being alive|life)#{PHRASE_END}/i,
      /\b(?:it['’]?s|its|life|life is|life['’]s)\s+(?:not|isn['’]?t|isnt|aint)\s+worth (?:living|it)#{SENTENCE_END}/i,
      /\b(?:don['’]?t|dont|do not)\s+(?:wanna|want to)\s+exist(?:\s+any\s?more)?#{PHRASE_END}/i,
      /\b(?:can['’]?t|cant|cannot|can not)\s+do life(?:\s+any\s?more)?#{PHRASE_END}/i,
      /\b(?:nobody|no one|noone)\s+would\s+(?:even\s+)?(?:miss|notice|care if)\s+(?:me|i (?:was|were) gone)\b/i,
      /\b(?:want|wanna|wish i could)\s+(?:to\s+)?(?:go to\s+)?sleep and (?:never|not) wake up\b/i
    ].freeze
    # Hopeless language that is not a stated plan to self-harm. Mia keeps helping
    # with the money question but always adds a gentle safety check. Each phrase
    # must end its clause ("I give up." / "whats the point"), so money objects
    # ("give up dining out", "hopeless with money", "point of a sinking fund") do
    # not match.
    CLAUSE_END = "(?=\\s*(?:[.!?,;…:]|\\z|\\b(?:lol|tbh|honestly|man|bro|already|anymore|any more|no more|any longer)\\b))"
    # "anymore" ends the phrase only when the sentence ends with it.
    POINT_END = "(?=\\s*(?:[.!?,;…:]|\\z|\\b(?:lol|tbh|honestly)\\b|any\\s?more\\s*(?:[.!?,…]|\\z)))"
    HOPELESS_PATTERNS = [
      /\b(?:don['’]?t|dont|do not)\s+(?:wanna|want to)\s+be (?:here|alive) any\s?more\s*,/i,
      /\b(?:don['’]?t|dont|do not)\s+(?:wanna|want to)\s+wake up(?:\s+(?:tomorrow|again|anymore))?\s*,/i,
      /\bi\s+wish\s+i\s+(?:wasn['’]?t|wasnt|weren['’]?t|was not|were not)\s+(?:here|alive|born)\s*,/i,
      /\bwant (?:it|this|everything) to (?:be over|end)#{CLAUSE_END}/i,
      /\b(?:don['’]?t|dont|do not) see (?:the|any) point(?:\s+any\s?more)?#{CLAUSE_END}/i,
      /\b(?:can['’]?t|cant|cannot|can not)\s+(?:do|take|handle|deal with)\s+(?:this|it|any of this)\s+(?:any\s?more|no more|any longer|much longer)\b/i,
      /\b(?:can['’]?t|cant|cannot|can not)\s+(?:do|take|handle)\s+this#{CLAUSE_END}/i,
      /\bi(?:['’]m|m|\s+am)?\s+(?:just\s+|so\s+|really\s+)?(?:giving up|give up|gave up|want to give up|ready to give up)(?:\s+on\s+(?:everything|life|myself))?#{CLAUSE_END}/i,
      /\bi(?:['’]m|m|\s+am)\s+(?:just\s+|so\s+)?done with (?:everything|it all|all of (?:it|this))#{CLAUSE_END}/i,
      /\b(?:can['’]?t|cant|cannot|can not)\s+(?:even\s+)?any\s?more#{CLAUSE_END}/i,
      /\b(?:no|there['’]?s no|theres no) point any\s?more(?=\s*(?:[.!?,;…]|\z|\b(?:lol|tbh|honestly)\b))/i,
      /\bjust want (?:it all|everything) to stop#{CLAUSE_END}/i,
      /\b(?:i(?:['’]m|m|\s+am)?\s+(?:so\s+|just\s+)?(?:feel(?:ing)?\s+)?|feel(?:ing)?\s+(?:so\s+)?)hopeless(?!\s+(?:with|at)\b)/i,
      /\btired of (?:everything|living|it all|life|trying)#{CLAUSE_END}/i,
      /\b(?:want to|wanna)\s+disappear#{CLAUSE_END}/i,
      /\b(?:what['’]?s (?:even )?the|whats (?:even )?the|what is (?:even )?the|there['’]?s no|theres no|is there any)\s+point(?:\s+(?:in anything|in trying|in any of this|in living|of anything|of any of this))?#{POINT_END}/i,
      /\b(?:i\s+)?(?:feel|am|i['’]m|im)\s+(?:like\s+)?(?:such\s+)?a burden\b/i
    ].freeze
    # "Should I give up?" asks for advice, not help.
    ADVICE_QUESTION_PATTERN = /\A\s*(?:should|can|could|would|do|does|is it|when do)\b[^.!?]*\?\s*\z/i
    WELLBEING_CHECK = "If you ever feel like you might hurt yourself, please call or text 988 right now, or 911 in an emergency. You deserve support, and the money plan can wait until you have it."
    WELLBEING_OPENING = "I’m really glad you told me, and feeling this way does not make you a failure."

    def self.matches?(message)
      normalized = message.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "").squish
      PATTERNS.any? { |pattern| normalized.match?(pattern) }
    end

    def self.hopeless?(message)
      normalized = message.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "").squish
      return false if matches?(normalized)

      sentences = normalized.split(/(?<=[.!?])\s+/)
      sentences.any? do |sentence|
        !sentence.match?(ADVICE_QUESTION_PATTERN) && HOPELESS_PATTERNS.any? { |pattern| sentence.match?(pattern) }
      end
    end

    # Adds an acknowledgement (when the reply has none) and the safety check to
    # any reply, model-written or scripted.
    def self.with_wellbeing_check(reply)
      text = reply.to_s
      return text if text.match?(/(?<![\d$,.])988(?!\d|[.,]\d)/)

      acknowledged = text.match?(/\b(?:not (?:a|mean you are a) failure|glad you (?:told|said)|(?:that|this) (?:sounds|feels|is) (?:so |really )?(?:heavy|hard|exhausting|overwhelming))\b/i)
      [ (acknowledged ? nil : WELLBEING_OPENING), text, WELLBEING_CHECK ].compact_blank.join(" ")
    end

    def self.response
      RuntimePersona::FALLBACKS.fetch("crisis")
    end
  end
end
