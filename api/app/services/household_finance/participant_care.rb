module HouseholdFinance
  module ParticipantCare
    module_function

    def topic(care, persona_context_id: nil)
      { "type" => "care", "title" => "Personal support", "care_kind" => (care.to_sym == :essentials ? "hardship" : care.to_s),
        "started_at" => Time.current.iso8601, "expires_at" => (Time.current + ParticipantCareState::TTL).iso8601,
        "persona_context_id" => persona_context_id }
    end

    # This protects release only; every other unresolved reply still stays in
    # care through state, without a follow-up vocabulary deciding its route.
    def followup?(message)
      ConversationFollowupResolver.acknowledgment?(message) || message.to_s.squish.match?(/\A(?:idk|i (?:just )?(?:dont|don't|do not) know|yeah|yes|no|maybe)[.!? ]*\z/i)
    end

    def explicit_recovery?(message)
      message.to_s.match?(/\b(?:all good now|(?:i|we)(?:['’]m|['’]re| am| are|m|re)? (?:doing|feeling) better now|(?:i|we) figured it out|(?:i|we)(?: am| are|['’]m|['’]re|m|re) (?:okay|ok|safe) now|(?:i|we) (?:am|are) safe)\b/i)
    end

    # Carrying on with setup, in her words. "i cant keep going" must never match.
    SETUP_RESUME = /\b(?:lets?|let['’]s|lemme|can we|could we|ok(?:ay)?|want to|wanna|ready to)\s+(?:pls\s+|please\s+|just\s+)?(?:keep\s+go\w*|continue|carry\s+on|go\s+on|finish|get\s+back|go\s+back|pick\s+(?:this|it)\s+back\s+up)\b|\b(?:finish|continue|resume)\s+(?:the\s+|my\s+|our\s+|this\s+)?setup\b/i
    SETUP_FIELD_WORDS = /\b(?:month|monthly|week|weeks|year|paycheck|check|checks|income|salary|bills?|rent|debts?|loans?|spend\w*|groceries)\b/i

    # Words that say the problem actually moved, as opposed to waving it away.
    RECOVERY_EVIDENCE = /\b(?:now|better|helping|helped|support\w*|sorted|settled|figured|worked out|got (?:food|help)|covered)\b/i
    BRUSH_OFF = /\b(?:fine|okay|ok|alright|all right|whatever|tired|nvm|never ?mind|don['’]?t worry|dont worry|no worries)\b/i

    def setup_resume?(message) = message.to_s.match?(SETUP_RESUME)

    # Setup information she actually gave, which is what ends a care topic. A
    # bare number may be the answer to a care question, so it needs a sign that
    # it belongs to setup.
    def setup_content?(message, reading)
      changes = reading.setup_changes.to_h
      return false if changes.empty?
      return true if setup_resume?(message) || Array(changes["skips"]).any?
      said = reading.care_status == "new_topic"
      return true if changes.values_at("household_name", "primary_goal").any?(&:present?) && (said || message.to_s.match?(/\b(?:goal|name|call (?:us|it))\b/i))

      [ *MiaSetupCard::MONEY_FIELDS, MiaSetupCard::DEBT_FIELD ].any? do |field|
        change = changes[field].to_h
        change["none"] || Array(change["parts"]).any? || (change["total"].present? && (said || message.to_s.match?(SETUP_FIELD_WORDS)))
      end
    end

    def brush_off?(message)
      text = message.to_s
      text.split.length <= 10 && !text.match?(/\d/) && text.match?(BRUSH_OFF) && !text.match?(RECOVERY_EVIDENCE) && !explicit_recovery?(text)
    end

    # The close repeats only what she said: thanks earns "You're welcome", and
    # someone helping earns "support".
    def closing_reply(message)
      text = message.to_s
      return if brush_off?(text)
      thanks = text.match?(ConversationFollowupResolver::GRATITUDE_PATTERN)
      support = text.match?(/\b(?:help\w*|support\w*|cousin|sister|brother|mom|dad|family|friend|coach)\b/i)
      return "I'm glad you have support and things feel more settled. You're welcome, and I'm here when you're ready." if thanks && support
      return "You're welcome, and I'm here when you're ready." if thanks

      "I'm glad things feel more settled. I'm here when you're ready."
    end

    def scenario_current_only?(history: [], context: {})
      return true if ParticipantMessageReader::Current.scenario_current_only
      conversation = context.to_h.deep_symbolize_keys[:conversation].to_h
      topics = [ conversation[:active_thread], *Array(conversation[:open_threads]) ]
      return true if topics.any? { |row| row.to_h[:type].to_s == "care" }

      rows = [ *Array(history), *Array(conversation[:recent_messages]) ]
      rows.last(32).any? do |row|
        data = row.to_h.symbolize_keys
        data[:role].to_s == "user" && data[:content].to_s.match?(Regexp.union(::Mia::SensitiveMoment::GRIEF, ::Mia::SensitiveMoment::STRAIN))
      end
    end

    def current_amounts(message)
      text = PurchaseReportText.normalize(message.to_s).gsub(PurchaseReportParser::DATE_PATTERN, " ")
      text.scan(/(?<![\w.,])\$?\s*(#{Money::CHAT_NUMBER_SOURCE}#{Money::CHAT_THOUSANDS_SOURCE}?)(?![\w.,])/).flatten.filter_map { |amount| Money.chat_cents(amount) rescue nil }
    end

    def purchase_reference_current?(message, reference)
      amounts = current_amounts(message)
      return false if amounts.empty?
      price = reference.to_s.match(/(?:\bso\s+(?:an?\s+)?|\AThe\s+)\$([\d,.]+)\s+(.+?)(?:\s+would|\s+price)/i)
      return PurchaseQuestionText.item_label(message).present? if reference.to_s.start_with?("There is no household plan")
      return false unless price && amounts.include?(Money.chat_cents(price[1]))
      item = price[2].downcase.strip
      item.in?(%w[purchase price]) || message.to_s.downcase.include?(item)
    rescue ArgumentError
      false
    end

    def kind(message)
      current = ParticipantMessageReader::Current
      if current.message.to_s.squish == message.to_s.squish && current.reading&.available
        return current.reading.care.to_sym if current.reading.care?
        if current.reading.care_status == "ongoing" && current.recent_care.present?
          return current.recent_care == "crisis" ? :hardship : current.recent_care.to_sym
        end
        return certain_kind(message)
      end
      if current.message.to_s.squish == message.to_s.squish && current.guard_care.present?
        return current.guard_care.to_sym unless current.guard_care == "none"
      end
      certain_kind(message)
    end

    def certain_kind(message)
      # Exact subject/action forms remain a deterministic floor. Idioms such
      # as dead set/dead tired and fired up never satisfy these forms.
      text = message.to_s.tr("’", "'").strip
      return nil if text.match?(/\b(?:so we moved|so i moved|used to|years? ago|all good now|doing better|figured it out)\b/i)
      return :grief if text.match?(/\A(?:(?:my|our) )?(?:mom|dad|mother|father|husband|wife|sister|brother|grandfather|grandmother|nana|tita|auntie|aunt|uncle) (?:just )?(?:died|passed(?: away)?)(?: (?:today|yesterday|this week|this weekend|last week|on \w+|\w+day))?(?=\s*(?:[.!?,;]|\z|\b(?:and|but|services|funeral|burial)\b))/i)
      return :grief if text.match?(/\A(?:i|we) (?:just )?buried (?:my|our) (?:husband|wife|mom|dad|mother|father|child|son|daughter)\b/i)
      return :job_loss if text.match?(/\A(?:i lost my job|my employer (?:fired me|let me go))(?: (?:today|yesterday|last week))?[.!]?\z/i)
      return :housing if text.match?(/\Awe are about to be evicted[.!]?\z/i)
      return nil if text.match?(/\b(?:so we moved|so i moved|used to|years? ago|all good now|doing better|figured it out)\b/i)
      return :housing if text.match?(/\b(?:can['’]?t|cant|cannot|won['’]?t|wont|unable to) (?:make|pay|cover|afford) (?:my |our |the )?rent\b/i)
      return :food if !text.match?(MoneyMovementText::NOT_HARDSHIP_PATTERN) && text.match?(/(?:\A|[,;.!]\s*)(?:we|i) (?:are |am )?(?:out of|have no|got no) food(?: money)?(?=\s*(?:[,.!?;]|\z|(?:until|til|till|today|tonight|left|and|because|so)\b))/i)
      return :food if MoneyMovementText.food_insecurity?(text)
      return nil if reading_available?(message)
      return :hardship if text.match?(/\b(?:my|our|the)?\s*(?:baby|child|husband|wife|mom|dad)\b.{0,30}\b(?:in (?:the )?hospital|hospitalized)\b/i)
      return :hardship if text.match?(/\b(?:cut|took away|lost)\b.{0,25}\b(?:my|our) (?:hours|shifts)\b/i)
      return :hardship if text.match?(/\b(?:truck|car) broke down\b/i) && text.match?(/\b(?:cant|can['’]?t|cannot) (?:get|go) to work\b/i)
      :essentials if MiaCoachAnswerer.essential_hardship?(text)
    end

    def reading_available?(message)
      current = ParticipantMessageReader::Current
      current.message.to_s.squish == message.to_s.squish && current.reading&.available
    end

    # When the shared reader is unavailable (including demo/preview calls), the
    # existing reply guard owns semantic care. No second reader is called.
    def guard_when_unread(message, history:, reply:, api_key: ENV["OPENROUTER_API_KEY"])
      current = ParticipantMessageReader::Current
      return if current.message.to_s.squish == message.to_s.squish && (current.reading&.available || current.guard_care.present?)
      return if api_key.to_s.strip.blank?

      guard = ::Mia::ReplyGuard.call(user_message: message, history: history, facts: {}, reply: reply, api_key: api_key)
      if current.message.to_s.squish == message.to_s.squish && guard.care
        current.guard_care = guard.care
      end
      guard
    end

    # An authoritative current "none" is not permission for generated crisis
    # instructions. Preserve explicit hotline questions and the crisis floor.
    def unexpected_crisis_guidance?(message, reply, care: nil)
      care = ParticipantMessageReader::Current.reading.care if reading_available?(message)
      return false unless care == "none"
      return false if ::Mia::CrisisBoundary.matches?(message) || ::Mia::CrisisBoundary.hopeless?(message)
      return false if message.to_s.match?(/\b(?:988|911|lifeline|crisis line)\b/i)

      ::Mia::CrisisBoundary.safety_reply?(reply) || reply.to_s.match?(/\b(?:call|dial|contact)\s+(?:the\s+)?911\b/i)
    end

    def fallback(message, reference)
      return reference if ParticipantCareState.report?(message, ParticipantMessageReader::Current.reading) if ParticipantMessageReader::Current.reading
      care = ParticipantMessageReader::Current.recent_care
      return reference unless care.present?
      return reference unless reference.to_s.match?(/That took effort, and it matters|not have enough approved data|Start with one purchase|add (?:your )?debt minimums|Still to add|starting household details|try again or use|Next setup question/i)

      answer(message, care: care)
    end

    def required?(message) = kind(message).present?

    def answer(message, care: nil)
      selected = care&.to_sym || kind(message)
      if selected.in?([ :hardship, :food, :housing, :job_loss ])
        if selected == :food || message.to_s.match?(/\b(?:food|eat|hungry|meals?|grocer\w*)\b/i)
          spend_note = MiaCoachAnswerer.spend_report_text?(message) ? " Your reported spending still needs review before it counts as spent." : ""
          return "Going without food is hard, and you deserve to eat. Food comes first for you and your family; saving and setup can wait. Please talk with your coach or someone you trust about getting food today and finding support nearby. I don't have verified local contacts to give you.#{spend_note} Do you have enough food for everyone, including you, today?"
        end
        if message.to_s.match?(/\b(?:what|how|can|cant|cannot|can't)\b/i) && message.to_s.match?(/\brent\b/i)
          return "Protect food, housing, utilities and medicine. If rent may be short, contact your landlord as soon as you can and ask about a payment arrangement; they may or may not agree. Ask your coach or someone you trust to help you work through the options. What is the rent due date?"
        end
      end
      case selected
      when :crisis
        ::Mia::CrisisBoundary.response
      when :grief
        "I'm sorry for your loss. You don't have to work through money or setup right now. If it helps, reach out to your coach or someone you trust. We can pick this up when you're ready. What would feel most helpful today?"
      when :shame
        "This doesn't define your worth. We can take this one step at a time, when you're ready. What would feel most helpful today?"
      when :hardship, :job_loss, :housing, :food
        "That sounds hard. Your safety, food, housing, utilities and medicine come first; savings and setup can wait. Reach out to your coach or someone you trust if that would help. We can pick this up when you're ready. What feels most urgent today?"
      end
    end
  end
end
