module Mia
  class CrisisBoundary
    FIRST_PERSON_SELF_HARM_INTENT_SOURCE = "(?:i(?:['’]m|\\s+am)\\s+(?:going\\s+to|about\\s+to|planning\\s+to|thinking\\s+(?:about|of))|i\\s+(?:want|plan|intend)\\s+to)".freeze
    # The phrase must end its clause, so "done with life insurance" or "point of
    # living paycheck to paycheck" stays money talk.
    TIME_WORDS = "(?:\\s+(?:today|tonight|tomorrow|rn|right now|soon|this weekend))?".freeze
    PHRASE_END = "(?=\\s*(?:[.!?,;…]|\\z|\\b(?:anyway|tbh|lol|honestly|fr|man)\\b))"
    # Stricter end: the sentence itself ends ("…wake up." not "…wake up, it's Monday").
    SENTENCE_END = "(?=\\s*(?:[.!?…]|\\z|\\b(?:tbh|honestly|fr)\\b))"
    LEGACY_SOFT_PATTERNS = [
      /\b(?:kill(?:ing)? myself|end(?:ing)? my life|tak(?:e|ing) my own life|end it all|want to die|suicidal|suicide|hurt(?:ing)? myself|harm(?:ing)? myself|self[-\s]?harm)\b/i,
      # Common texting slang for the same thing.
      /(?<!the )(?<!my )(?<!of )(?<!\d )(?<!\d)\bkmsl?\b/i,
      /\b(?:unaliv(?:e|ing) myself|off(?:ing)? myself)\b/i,
      /(?:\A\s*|\b(?:i|im|i['’]m|i am|ima|i['’]ma)\s+(?:\w+\s+)?)(?:wanna|want ta|gonna|going to|finna)\s+(?:just\s+)?(?:die|end it(?=\s*(?:[.!?,;…]|\z|\b(?:all|tonight|today|now|fr|tbh|lol)\b))|end my life|kill myself)\b/i,
      /\b#{FIRST_PERSON_SELF_HARM_INTENT_SOURCE}\s+(?:shoot(?:ing)?|hang(?:ing)?|drown(?:ing)?|stab(?:bing)?|poison(?:ing)?|suffocat(?:e|ing))\s+myself\b/i,
      /\b#{FIRST_PERSON_SELF_HARM_INTENT_SOURCE}\s+overdos(?:e|ing)\b/i,
      /\bi\s+wish\s+i\s+(?:were|was)\s+(?:dead|not alive)\b|\bi(?:['’]d|\s+would)\s+rather\s+be\s+dead\b/i,
      # "live" must end the clause: "don't wanna live paycheck to paycheck" is money talk.
      /\b(?:don['’]?t|dont|dnt|do not)\s+(?:want to|wanna|wana)\s+(?:be alive|live|keep living)(?:\s*any\s?more)?#{PHRASE_END}/i,
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
      /\b(?:nobody|no one|noone)\s+would\s+(?:even\s+)?(?:miss\s+me|(?:notice|care)\s+if\s+i\s+(?:(?:was|were) gone|(?:wasn['’]?t|wasnt|weren['’]?t) here))\b#{TIME_WORDS}#{PHRASE_END}/i,
      /\b(?:want|wanna|wish i could)\s+(?:to\s+)?(?:go to\s+)?sleep and (?:never|not) wake up\b/i,
      # Death wishes and texting forms.
      /\bi(?:['’]?d| would)\s+be\s+better\s+off\s+dead\b|\b(?:i\s+am|i['’]?m|im)\s+better\s+off\s+dead\b/i,
      /\bi\s+(?:feel|felt)\s+like\s+dying#{TIME_WORDS}#{PHRASE_END}/i,
      /\b(?:thinking|thought)\s+(?:of|about)\s+ending\s+(?:things|it all|it|everything)#{TIME_WORDS}#{PHRASE_END}/i,
      /\b(?:thinking|thought)\s+(?:of|about)\s+ending\s+(?:things\s+)?with\s+my\s+life\b/i,
      /\bending it all#{TIME_WORDS}#{PHRASE_END}/i,
      /\b(?:wanna|want to|going to|gonna|need to)\s+unaliv(?:e|ing)(?:\s+(?:myself|me)\b|#{TIME_WORDS}#{PHRASE_END})/i,
      # "kys" only as a whole message or sentence, never inside other words.
      /(?:\A\s*|[.!?]\s+)kys#{PHRASE_END}/i,
      # Stating that they are not safe, or that they have a plan to die.
      /\b(?:i\s*am|i['’]?m|im)\s+not\s+saf(?:e)?(?:\s+(?:here|at home|with myself))?#{TIME_WORDS}#{PHRASE_END}/i,
      /\bi\s+(?:have|got|made)\s+a\s+plan\s+(?:to|for)\s+(?:(?:kill(?:ing)?|hurt(?:ing)?|harm(?:ing)?)\s+myself|end(?:ing)?\s+my\s+life|suicide\b|(?:end(?:ing)?\s+it(?:\s+all)?|die|dying)#{TIME_WORDS}#{PHRASE_END})/i,
      /\b(?:i (?:have|see) )?no reason to keep (?:going|living)#{PHRASE_END}/i,
      /\b(?:i['’]?m|im|i am|i feel like) (?:just |such )?a burden#{PHRASE_END}/i
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
      # "here" must end the clause, so "don't want to be here when the bill comes"
      # or "...at the store all day" stays money talk.
      /\b(?:don['’]?t|dont|do not)\s+(?:wanna|want to)\s+be here(?:\s+any\s?more)?#{CLAUSE_END}/i,
      /\bi\s+wish\s+i\s+could\s+(?:just\s+)?(?:not exist|disappear|vanish)#{CLAUSE_END}/i,
      /\b(?:what['’]?s|whats|what is) the point of (?:anything|everything|it all)#{POINT_END}/i,
      /\bnothing (?:even )?matters(?:\s+any\s?more)?#{CLAUSE_END}/i,
      /\bwant (?:it|this|everything) to (?:be over|end)#{CLAUSE_END}/i,
      /\b(?:don['’]?t|dont|do not) see (?:the|any) point(?:\s+any\s?more)?#{CLAUSE_END}/i,
      /\b(?:can['’]?t|cant|cannot|can not)\s+(?:do|take|handle|deal with)\s+(?:this|it|any of this)\s+(?:any\s?more|no more|any longer|much longer)(?=\s*(?:[.!?,;…:]|\z|\b(?:lol|tbh|honestly|man|bro)\b))/i,
      /\b(?:can['’]?t|cant|cannot|can not)\s+(?:do|take|handle)\s+this(?=\s*(?:[.!?,;…:]|\z|\b(?:lol|tbh|honestly)\b))/i,
      /\bi(?:['’]m|m|\s+am)\s+(?:just\s+|so\s+)?done with (?:everything|it all|all of (?:it|this))#{CLAUSE_END}/i,
      /\b(?:can['’]?t|cant|cannot|can not)\s+(?:even\s+)?any\s?more#{CLAUSE_END}/i,
      /\b(?:no|there['’]?s no|theres no) point any\s?more(?=\s*(?:[.!?,;…]|\z|\b(?:lol|tbh|honestly)\b))/i,
      /\bjust want (?:it all|everything) to stop#{CLAUSE_END}/i,
      /\b(?:i(?:['’]m|m|\s+am)?\s+(?:so\s+|just\s+)?(?:feel(?:ing)?\s+)?|feel(?:ing)?\s+(?:so\s+)?)hopeless(?!\s+(?:with|at)\b)/i,
      /\btired of (?:everything|living|it all|life|trying)#{CLAUSE_END}/i,
      /\b(?:want to|wanna)\s+disappear#{CLAUSE_END}/i,
      /\b(?:what['’]?s (?:even )?the|whats (?:even )?the|what is (?:even )?the|there['’]?s no|theres no|is there any)\s+point(?:\s+(?:in anything|in trying|in any of this|in living|of anything|of any of this))?#{POINT_END}/i,
      /\b(?:i\s+)?(?:feel|am|i['’]m|im)\s+(?:like\s+)?(?:such\s+)?a burden\b/i,
      /\b(?:feel(?:ing)?|am|i['’]m|im)\s+(?:like\s+)?(?:such\s+a|a\s+(?:total|complete))\s+failure\b/i,
      /\b(?:failure|worthless|useless|stuck|behind|lost|broken)(?:\s+(?:and|&)|,)\s+(?:so\s+|just\s+|completely\s+)?hopeless(?!\s+(?:with|at)\b)/i
    ].freeze
    # "I give up." Kept separate so an advice question ("Should I give up?") can be
    # set aside without hiding other hopeless words in the same sentence.
    GIVE_UP_PATTERN = /\bi(?:['’]m|m|\s+am)?\s+(?:just\s+|so\s+|really\s+)?(?:giving up|give up|gave up|want to give up|ready to give up)(?:\s+on\s+(?:everything|life|myself))?#{CLAUSE_END}/i
    # "Should I give up?" asks for advice, not help.
    ADVICE_QUESTION_PATTERN = /\A\s*(?:should|can|could|would|do|does|is it|when do)\b[^.!?]*\?\s*\z/i
    # Only a current first-person intent with a named self-harm action is an
    # immediate boundary. Wishes, social absence, idioms and other ambiguous
    # wording belong to the reader-assisted tier below.
    INTENT_SOURCE = "(?:want(?:\\s+to)?|wanna|wana|wna|will|gonna|gona|gunna|going\\s+(?:to|2)|about\\s+to|planning\\s+to|plan\\s+to|intend\\s+to|thinking\\s+(?:of|about))".freeze
    SELF_ACTION_SOURCE = "(?:k(?:ill|il|ll)(?:ing)?|hurt(?:ing)?|harm(?:ing)?|hang(?:ing)?|shoot(?:ing)?|drown(?:ing)?|stab(?:bing)?|poison(?:ing)?|suffocat(?:e|ing)|unaliv(?:e|ing)|off(?:ing)?)\\s+myself|end(?:ing)?\\s+my\\s+life|tak(?:e|ing)\\s+my\\s+own\\s+life".freeze
    EXPLICIT_PATTERNS = [
      /\b(?:i(?:['’]m|\s+am)?|im|ima|i['’]ma)\s+(?:just\s+)?#{INTENT_SOURCE}\s+(?:just\s+)?(?:#{SELF_ACTION_SOURCE})\b/i,
      /(?:\A|[.!?;]\s*)(?:gonna|gona|gunna|going to|wanna|wana|finna)\s+(?:just\s+)?(?:#{SELF_ACTION_SOURCE})\b/i,
      /\bi\s+(?:have|got|made)\s+a\s+plan\s+(?:to|for)\s+(?:(?:#{SELF_ACTION_SOURCE})\b|(?:die|suicide)#{TIME_WORDS}#{PHRASE_END})/i,
      /\b(?:i(?:['’]m|\s+am)?|im)\s+#{INTENT_SOURCE}\s+(?:just\s+)?die#{TIME_WORDS}#{PHRASE_END}/i,
      /\b(?:i(?:['’]m|\s+am)?|im)\s+#{INTENT_SOURCE}\s+(?:just\s+)?overdos(?:e|ing)(?:\s+on\s+(?:(?:all\s+)?my\s+)?pills?)?#{TIME_WORDS}#{PHRASE_END}/i,
      /\b(?:i(?:['’]m|\s+am)?|im)\s+(?:wanna|want to|gonna|will|might)\s+kms\b/i
    ].freeze
    # Missing spaces are common in rushed disclosures. This matches the same
    # intent/action structure, not a bag of self-harm words.
    COMPACT_EXPLICIT = /(?:i(?:['’]?m|am)?|\A)(?:(?:really|rlly|just|actually|seriously|honestly|desperately))*(?:wantto|wanna|wana|will|gonna|gona|gunna|goingto|going2|aboutto|planto|intendto)(?:(?:really|rlly|just|actually|seriously|honestly|desperately))*(?:k(?:ill|il|ll)myself|hurtmyself|harmmyself|hangmyself|shootmyself|endmylife|takemyownlife|overdose|die)(?:(?:to|2)?night|tonite|today|tomorrow|now|rn)?\b/i
    SOFT_FAMILIES = [
      /\b(?:stop|stopping)\s+existing\b/i,
      /\b(?:wish|hope)\b[^.!?]{0,55}\b(?:never|not)\s+(?:been\s+)?born\b/i,
      /\b(?:dont|don['’]?t|do not)\s+(?:wanna|wana|want to)\s+wake up\b/i,
      /\b(?:want|wanna|wish)\s+(?:it all|everything|life)\s+to\s+(?:end|stop|be over)\b/i,
      /\b(?:kill|killing|end|ending|hurt|hurting|harm|harming|hang|hanging|shoot|shooting|off|unalive)\s+(?:my\s*self|my own life|my life)\b/i,
      /\b(?:suicid[ae]?|s[ui]{0,3}c[ui]{0,3}d[aie]{0,3}l(?:ity|ly)?)\b/i,
      /\b(?:overdos\w*|pills?|self[- ]?harm)\b/i,
      /\b(?:wish|hope|hoping)\b[^.!?]{0,65}\b(?:dead|die|dying|never born|not born|wake up)\b/i,
      /\b(?:wish|hope|hoping)\b[^.!?]{0,65}\b(?:wasn['’]?t|wasnt|weren['’]?t|were not|was not)\s+(?:here|alive|born)\b/i,
      /\b(?:end(?:ing)?|over)\s+(?:it|it all|everything|things)#{TIME_WORDS}#{PHRASE_END}/i,
      /\bbetter\s+(?:off\s+)?(?:dead|gone|without me|w\/o me)\b|\bbetter\s+off\s+if\s+i\s+(?:was|were)\s+(?:dead|gone)\b/i,
      /\b(?:world|everyone|everybody|evryone|family|kids|children)\b[^.!?]{0,55}\bbetter\b[^.!?]{0,35}\b(?:without me|w\/o me)\b/i,
      /\bi\s+(?:(?:want to|wanna|wish i could|just|could|should|will|might)\s+)*(?:disappear\w*|vanish\w*)\b/i,
      /\b(?:nobody|no one|noone)\b[^.!?]{0,55}\b(?:care|notice|miss)\b[^.!?]{0,45}\b(?:died|dead|gone|disappear\w*|wasn['’]?t|wasnt|weren['’]?t|around)\b/i,
      /\b(?:nobody|no one|noone)\s+(?:even\s+)?needs?\s+me\b/i,
      /\b(?:dont|don['’]?t|dnt|do not)\s+(?:(?:wanna|wana|want to|want ta)\s+)?(?:b|be)\s+(?:here|alive)\s+(?:any\s?more|no more|tomorrow|tonight|much longer)\b/i,
      /\bidw\s+(?:b|be)\s+here\b/i,
      /\b(?:dont|don['’]?t|dnt|do not)\s+(?:wanna|wana|want to)\s+(?:live|exist)(?:\s+(?:no more|any\s?more))?#{PHRASE_END}/i,
      /\b(?:can['’]?t|cant|cannot|can not)\s+keep\s+(?:going|living)\b/i,
      /\b(?:dont|don['’]?t|do not)\s+see\s+(?:a|any)\s+way\s+out\b|\b(?:there['’]?s|theres|there is)\s+no\s+way\s+out\b/i,
      /\b(?:wont|won['’]?t|will not|not gonna|not going to)\s+(?:b|be)\s+(?:here|around)\s+(?:much longer|any longer|next week|tomorrow|soon)\b/i,
      /\b(?:soon|tomorrow)\b[^.!?]{0,35}\b(?:wont|won['’]?t|will not)\s+be\s+(?:a\s+)?problem\b/i,
      /\btired\s+of\s+being\s+alive\b|\b(?:no reason|nothing)\s+(?:to|left to)\s+(?:live|keep going|keep living)\b|\bnothing\s+to\s+live\s+for\b/i,
      /\b(?:point\s+(?:of|in)\s+(?:going on|living)|deserve\s+to\s+live|life\b[^.!?]{0,20}\bworth\s+living)\b/i,
      /\b(?:i['’]?m|im|i am|i feel|we are|we['’]re)\s+(?:(?:just|such|like|so|really)\s+)*(?:a\s+)?burden\b/i,
      /\b(?:might|could)\s+(?:just\s+)?do\s+something\s+to\s+myself\b/i,
      /\bjump\s+(?:off|from)\b/i,
      /\b(?:ready|want|wanna)\b[^.!?]{0,25}\b(?:go|be)\b[^.!?]{0,20}\bwith\s+(?:my|our)\s+(?:mom|dad|mother|father|parents?|husband|wife|child|baby)\b/i
    ].freeze

    PERSONAL_NET = /\b(?:better off (?:dead|gone)|i (?:wish i (?:was|were)|(?:would|could|should|might) (?:just )?be) dead(?! rich)|if i (?:was|were) gone|(?:wont|won['’]?t|will not) be (?:here|around) much longer|debt (?:dies|die) with me|(?:might|may) as well be dead|(?:my|the) (?:very )?last budget|last budget|no reason to keep (?:going|living).*\bgoodbye|(?:goodbye|farewell).*(?:life|world|kids|family)|(?:world|everyone|everybody).{0,40}without me|burden (?:on|to) (?:my |our |the )?(?:kids|children|family|parents|husband|wife|partner|people|everybody|everyone)|better off if i (?:just )?(?:wasn['’]?t|wasnt|weren['’]?t) here|tired of being here|better off (?:with|w) (?:the |my )?insurance money|(?:not |won['’]?t be |wont be )?making it to christmas|driv(?:e|ing) off the road)\b/i
    EXTRA_EXPLICIT = [
      /\b(?:i(?:['’]m| am)?|im)\s+(?:(?:really|rlly|just|actually|seriously|honestly|desperately)\s+)*#{INTENT_SOURCE}\s+(?:(?:really|just|actually|seriously)\s+)*(?:#{SELF_ACTION_SOURCE}|die|slit (?:my )?wrists|cut (?:my )?wrists)\b/i,
      /\b(?:i(?:['’]m| am)?\s+|im\s+)?(?:gonna|going to|will|want to)\s+(?:swallow|take)\s+(?:all|a whole bottle of)\s+(?:my )?(?:meds|medications|pills|tylenol)\b/i,
      /\bi (?:got|have) a gun\b[^.!?]{0,60}\b(?:going to|gonna|will) use it on myself\b/i,
      /\bi (?:just )?(?:took|swallowed) (?:a |the )?whole bottle of (?:tylenol|pills|meds|medication)\b/i
    ].freeze

    WELLBEING_CHECK = "If you ever feel like you might hurt yourself, please call or text 988 right now, or 911 in an emergency. You deserve support, and the money plan can wait until you have it."
    WELLBEING_OPENING = "I’m really glad you told me, and feeling this way does not make you a failure."

    def self.normalized(message)
      message.to_s.unicode_normalize(:nfkc).gsub(/\p{Cf}/, "").tr("’", "'").gsub(/\bmy\s+self\b/i, "myself").gsub(/\s+/, " ").strip
    end

    def self.explicit?(message)
      text = normalized(message).gsub(/k[1!]ll/i, "kill")
      return false if text.match?(/\Aif i (?:see|get) (?:one more|another) (?:fee|bill|tax) (?:im|i['’]m|i am) (?:gonna|going to) die (?:lol|lmao|haha)[.!?]*\z/i)
      return true if EXTRA_EXPLICIT.any? { |pattern| text.match?(pattern) }
      EXPLICIT_PATTERNS.any? { |pattern| text.match?(pattern) } || text.delete(" ").match?(COMPACT_EXPLICIT)
    end

    def self.soft?(message)
      text = normalized(message)
      return false if explicit?(text)
      return true if text.match?(PERSONAL_NET)
      if bounded_ordinary?(text)
        # Remove the bounded trigger, not other risk wording in the message.
        text = text.gsub(/\bpills?\b/i, "medicine").gsub(/\bburden\b/i, "load")
          .gsub(/\b(?:disappear\w*|vanish\w*)\b/i, "change")
          .gsub(/\b(?:wont|won['’]?t|will not|not going to) be (?:here|around)\b/i, "travel")
      end

      (LEGACY_SOFT_PATTERNS + SOFT_FAMILIES + HOPELESS_PATTERNS).any? { |pattern| text.match?(pattern) } ||
        (text.match?(GIVE_UP_PATTERN) && !text.match?(ADVICE_QUESTION_PATTERN))
    end

    def self.matches?(message, **reader_options)
      return true if explicit?(message)
      return false unless soft?(message)

      reading = HouseholdFinance::ParticipantMessageReader.read_once(message: message, **reader_options)
      !reading.available || reading.care == "crisis"
    end

    # "I have a plan" alone is ambiguous ("I have a plan for my budget"), so it
    # counts only when the previous user turn was already crisis or hopeless.
    BARE_PLAN_PATTERN = /\A\s*(?:yes[,.!]?\s+|yeah[,.!]?\s+)?i\s+(?:do\s+)?(?:have|got)\s+a\s+plan\s*[.!]*\s*\z/i

    def self.plan_followup?(message, previous_user_message)
      return false unless message.to_s.unicode_normalize(:nfkc).match?(BARE_PLAN_PATTERN)

      matches?(previous_user_message) || hopeless?(previous_user_message)
    end

    # A narrow second safety net never turns ordinary money-object wording
    # into crisis. It only supplements normal help after a semantic none/shame.
    def self.hopeless?(message)
      return false unless normalized(message).match?(PERSONAL_NET)
      current = HouseholdFinance::ParticipantMessageReader::Current
      reading = current.reading if current.message.to_s.squish == message.to_s.squish
      reading&.available && %w[none shame].include?(reading.care)
    end

    def self.bounded_ordinary?(text)
      return false if text.match?(/\b(?:kill|hurt|harm|overdos\w*|suicid\w*|swallow|take (?:them |it )?all|whole bottle|dead|die|dying|myself)\b/i)
      return true if text.match?(/\bpills?\b/) && text.match?(/\b(?:refill|cost|price|prescription|pharmacy)\b|\$?\d/i)
      return true if text.match?(/\bburden\b/i) && !text.match?(/\b(?:i|im|i['’]m|myself|we)\b/i)
      return true if text.match?(/\b(?:money|savings|paycheck|cash|funds)\b.{0,35}\b(?:disappear\w*|vanish\w*)\b/i)
      return true if text.match?(/\b(?:disappear\w*|vanish\w*)\b.{0,35}\b(?:money|savings|cash|creditors? call lists?)\b/i)
      text.match?(/\b(?:wont|won['’]?t|will not|not going to) be (?:here|around)\b/i) &&
        text.match?(/\b(?:travel\w*|vacation|visiting|flight|trip)\b|\bon (?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/i)
    end

    # Adds an acknowledgement (when the reply has none) and the safety check to
    # any reply, model-written or scripted.
    def self.with_wellbeing_check(reply)
      text = reply.to_s
      return text if includes_wellbeing_check?(text)

      acknowledged = text.match?(/\b(?:not (?:a|mean you are a) failure|glad you (?:told|said)|(?:that|this) (?:sounds|feels|is) (?:so |really )?(?:heavy|hard|exhausting|overwhelming))\b/i)
      [ (acknowledged ? nil : WELLBEING_OPENING), text, WELLBEING_CHECK ].compact_blank.join(" ")
    end

    def self.includes_wellbeing_check?(reply)
      # A crisis-line instruction, not any number 988 ("rent is 988 dollars").
      reply.to_s.match?(/\b(?:call|text|dial|contact|reach)(?:\s+or\s+(?:call|text))?\s+(?:the\s+)?988\b|\b988\s+(?:suicide|lifeline|crisis)|\bsuicide (?:&|and) crisis lifeline\b/i)
    end

    def self.response
      RuntimePersona::FALLBACKS.fetch("crisis")
    end

    # True for a crisis reply or any reply carrying the wellbeing check. The
    # client hides money prompts and cards under such a reply.
    def self.safety_reply?(reply)
      text = reply.to_s
      text == response || includes_wellbeing_check?(text)
    end
  end
end
