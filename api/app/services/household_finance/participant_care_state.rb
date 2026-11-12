module HouseholdFinance
  # Private conversation state, never a financial scenario. Ordinary replies keep
  # a fixed deadline; every new crisis disclosure renews the safety window.
  class ParticipantCareState
    TTL = 48.hours
    REPORT_KINDS = %w[purchase set_aside withdrawal nothing_saved income].freeze
    # How the product works is a different topic, whatever the care label says.
    PRODUCT_QUESTION = /\b(?:pause|resume|leave|quit|stop|restart|withdraw|cancel)\b[^.!?]{0,40}\b(?:challenge|program|app)\b/i

    def initialize(session, persona_context_id: nil)
      @session, @persona_context_id = session, persona_context_id
    end

    def active
      @session.with_lock { active_locked }
    end

    def active_locked
      topic = stored_topic
      return unless topic["type"] == "care" && topic["care_kind"].present?
      expiry = Time.zone.parse(topic["expires_at"].to_s) rescue nil
      legacy = expiry.nil?
      expiry ||= (@session.chat_messages.order(:id).last&.created_at || @session.updated_at) + TTL
      if expiry > Time.current
        if legacy
          topic = topic.merge("started_at" => (expiry - TTL).iso8601, "expires_at" => expiry.iso8601)
          persist_topic!(topic)
        end
        return topic
      end

      archive(topic)
      @session.release_care_topic!
      nil
    end
    private :active_locked

    def transition(message, reading, history:)
      @session.with_lock { transition_locked(message, reading, history: history) }
    end

    def transition_locked(message, reading, history:)
      prior = active
      report = self.class.report?(message, reading)
      financial = MiaMonthAnswer.question?(message) || ::Mia::FinancialReadOnlyRequest.matches?(message) || PurchaseQuestionText.purchase_question?(message) || message.match?(/\A\s*how much (?:is|do i have) left(?: this month)?[?.! ]*\z/i)
      current = if reading.available
        reading.care? ? reading.care.to_sym : ParticipantCare.certain_kind(message)
      else
        ParticipantCare.kind(message)
      end
      recovery = ParticipantCare.explicit_recovery?(message)
      recovered = !reading.available && recovery
      settled = (reading.care_status == "new_topic" || (reading.care_status == "resolved" && ParticipantCare.closing_reply(message))) &&
        !(prior && (ParticipantCare.brush_off?(message) || ParticipantCare.current_hardship_sign?(message)))
      released = current.nil? && !ParticipantCare.followup?(message) &&
        (recovered || report || reading.answer_field.present? || ParticipantCare.setup_content?(message, reading) || financial || (reading.question && message.match?(PRODUCT_QUESTION)) || MiaSetupGuide.setup_request?(message) || (reading.available && settled))
      released = ParticipantCare.crisis_recovery?(message) if prior && prior["care_kind"] == "crisis"
      if released
        archive(prior) if prior
        @session.release_care_topic! if prior
        return nil
      end
      return unless current || prior

      kind = current || prior.fetch("care_kind")
      kind = :food if (current.in?([ :hardship, :essentials ]) || (prior && current.nil?)) && message.match?(/\b(?:food|hungry|eat|eaten|eating|grocer\w*)\b/i)
      kind = :housing if current == :hardship && message.match?(/\brent\b/i)
      kind = :hardship if kind.to_s == "essentials"
      kind = "crisis" if prior && prior["care_kind"] == "crisis"
      topic = prior || ParticipantCare.topic(kind, persona_context_id: @persona_context_id)
      topic = record_disclosure(topic, message)
      topic = topic.merge("type" => "care", "care_kind" => kind.to_s, "last_care_at" => Time.current.iso8601,
        "disclosure" => topic.fetch("disclosure"),
        "last_question" => Array(history).reverse.find { |row| row[:role].to_s == "assistant" }&.fetch(:content, "").to_s.last(700))
      persist_topic!(topic)
      topic
    end

    private :transition_locked

    # Every participant turn in an unresolved care episode can clarify means,
    # intent, timing or a prior ambiguous reference. Never replace earlier facts.
    def record_disclosure(topic, message)
      disclosures = Array(topic["disclosures"]).dup
      if disclosures.empty? && topic["disclosure"].present?
        disclosures << { "content" => topic["disclosure"], "created_at" => topic["started_at"] }
      end
      disclosures << { "content" => message.to_s, "created_at" => Time.current.iso8601(6) }
      CareDisclosures.bound_topic(topic.merge("disclosures" => disclosures))
    end

    def record_turn(message)
      @session.with_lock do
        topic = active
        next unless topic
        topic = record_disclosure(topic, message).merge("last_care_at" => Time.current.iso8601)
        persist_topic!(topic)
        topic
      end
    end

    def record_crisis(message)
      @session.with_lock do
        topic = active || ParticipantCare.topic(:crisis, persona_context_id: @persona_context_id)
        expiry = Time.zone.parse(topic.fetch("expires_at"))
        topic = record_disclosure(topic, message).merge("care_kind" => "crisis", "last_care_at" => Time.current.iso8601,
          "expires_at" => [ expiry, Time.current + TTL ].max.iso8601)
        persist_topic!(topic)
        topic
      end
    end

    # The daily check-in prompt waits while care is open, and for the rest of the
    # day (Guam time) after the last care reply, even if care has since closed.
    # Read-only: a plain page load must not change the conversation.
    def checkin_hold?(safety_reply_at: nil)
      topic = stored_topic
      if topic["type"] == "care"
        expiry = Time.zone.parse(topic["expires_at"].to_s) rescue nil
        expiry ||= (@session.chat_messages.maximum(:created_at) || @session.updated_at) + TTL
        return true if expiry > Time.current
      end

      # A historical safety flag expires only with its own care episode. An
      # unrelated earlier episode cannot release a new wellbeing check.
      if safety_reply_at && !safety_reply_in_episode?(topic, safety_reply_at)
        return true unless Array(@session.open_topics).any? { |row| safety_reply_in_episode?(row.to_h.deep_stringify_keys, safety_reply_at, archived: true) }
      end

      Array(@session.open_topics).any? do |row|
        archived = row.to_h.deep_stringify_keys
        next false unless archived["type"] == "care"

        last = Time.zone.parse((archived["last_care_at"] || archived["started_at"]).to_s) rescue nil
        last.present? && last.to_date == Time.zone.today
      end
    end

    # A money question can end the topic before recovery is said out loud.
    def recently_released?
      Array(@session.open_topics).any? do |row|
        topic = row.to_h.deep_stringify_keys
        topic["type"] == "care" && topic["care_kind"] != "crisis" && (Time.zone.parse(topic["expires_at"].to_s) rescue Time.at(0)) > Time.current
      end
    end

    def self.report?(message, reading)
      reading.facts.any? { |fact| REPORT_KINDS.include?(fact["kind"]) } ||
        (!reading.available && (MiaCoachAnswerer.spend_report_text?(message) || MoneyMovementText.savings_deposit?(message) || message.match?(/\b(?:put away|set aside|saved)\s+\$?\d/i)))
    end

    private

    # The non-text safety hold survives privacy deletion and topic writers.
    # Ordinary care topics remain compatible with existing conversation readers.
    def stored_topic
      topic = @session.active_topic.to_h.deep_stringify_keys
      hold = @session.care_hold.to_h.deep_stringify_keys
      expiry = Time.zone.parse(hold["expires_at"].to_s) rescue nil
      # A stale topic writer cannot downgrade a separately retained crisis.
      if hold["care_kind"] == "crisis" && expiry && expiry > Time.current &&
          !(topic["care_kind"] == "crisis" && topic["started_at"] == hold["started_at"])
        return hold
      end
      topic["type"] == "care" && topic["care_kind"].present? ? topic : hold
    end

    def persist_topic!(topic)
      @session.update!(active_topic: topic, care_hold: topic.slice("type", "care_kind", "started_at", "expires_at"))
    end

    def safety_reply_in_episode?(topic, replied_at, archived: false)
      return false unless topic["type"] == "care"
      started = Time.zone.parse(topic["started_at"].to_s) rescue nil
      end_key = archived ? (topic["ended_at"].present? ? "ended_at" : "last_care_at") : "expires_at"
      ended = Time.zone.parse(topic[end_key].to_s) rescue nil
      tolerance = end_key == "ended_at" ? 0 : 1.second
      started.present? && ended.present? && replied_at >= started && replied_at <= ended + tolerance
    end

    def archive(topic)
      # Narration can finish seconds after last_care_at. Record the episode's
      # actual end so its completed safety reply is still recognized after expiry.
      expiry = Time.zone.parse(topic["expires_at"].to_s) rescue nil
      topic = topic.merge("ended_at" => [ Time.current, expiry ].compact.min.iso8601(6))
      @session.update!(open_topics: (Array(@session.open_topics).reject { |row| row.to_h["type"] == "care" } + [ topic ]).last(8))
    end
  end
end
