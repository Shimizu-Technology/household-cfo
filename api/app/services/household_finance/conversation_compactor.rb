require "securerandom"

module HouseholdFinance
  class ConversationCompactor
    MAX_TOPICS = 8
    MAX_TEXT_LENGTH = 240
    AMOUNT_PATTERN = /\$\s*((?:\d{1,3}(?:,\d{3})+|\d{1,9})(?:\.\d{1,2})?)(?![\d,])/.freeze
    FOLLOW_UP_PATTERN = /\b(?:what if|does that change|what about|how about|and if|then what|should i|should we|can i|can we|it|they|them|that|this|those|remind me|pick up|continue|same thing|from earlier|we were talking)\b/i.freeze
    FAMILY_TERMS = /\b(?:cousin|family|auntie|aunty|uncle|sibling|brother|sister|parent|mom|dad|friend|off-island)\b/i.freeze
    FAMILY_ACTION_TERMS = /\b(?:asked|asking|ask|borrow|lend|loan|help|support|give|send)\b/i.freeze
    CAR_REPAIR_TERMS = /\b(?:car|vehicle|auto)\s+repair\b|\brepair\b.*\b(?:car|vehicle|auto)\b/i.freeze
    CAR_REGISTRATION_TERMS = /\b(?:(?:car|vehicle|auto)\s+)?(?:registration|tags?)\b/i.freeze
    JOB_TERMS = /\b(?:leave|quit|reduce|cut)\b.*\b(?:job|work|hours?)\b|\bbusiness\b.*\b(?:income|client|contract|full-time|run|job|work|hours?)\b/i.freeze
    DEBT_TERMS = /\b(?:debt|credit card|payday loan|balance transfer|consolidat|minimum payment|highest interest|smallest balance|payoff)\b/i.freeze
    SINKING_TERMS = /\b(?:sinking fund|school uniforms?|back.?to.?school|fridge|appliance|insurance renewal|renewal|gifts?|home repair)\b/i.freeze
    PENDING_TERMS = /\b(?:pending drafts?|transaction drafts?|confirm them|ignore them|waiting for review)\b/i.freeze
    REPORT_TERMS = /\b(?:budget|spending|spent|actuals?|over plan|under plan|categories?|dining out|groceries|report)\b/i.freeze
    READINESS_TERMS = /\b(?:red|yellow|green|readiness|runway|baseline|next paycheck|30-day reset)\b/i.freeze
    PURCHASE_TERMS = /\b(?:buy|purchase|spend|afford|get|book|order|trip|vacation|staycation|shoes|phone|takeout|hotel)\b/i.freeze
    TRANSACTION_TERMS = /\b(?:i|we)\s+(?:spent|paid|charged|bought|withdrew)\b/i.freeze

    def initialize(chat_session, user_message:, assistant_message:, follow_up: false)
      @chat_session = chat_session
      @user_message = user_message
      @assistant_message = assistant_message
      @follow_up = follow_up
      @now = Time.current
    end

    def call
      return false unless chat_session && user_message && assistant_message

      chat_session.with_lock do
        topics = normalized_topics(chat_session.open_topics)
        active_topic = normalized_topic(chat_session.active_topic)
        extracted_topic = extract_topic(user_message.content)
        topic = topic_to_update(extracted_topic, active_topic)

        if topic
          topic = merge_topic(topic, user_message.content, assistant_message.content)
          topics = upsert_topic(topics, topic)
        end

        active_topic = topic || active_topic
        chat_session.update!(
          active_topic: active_topic.presence || {},
          open_topics: topics,
          rolling_summary: build_summary(topics),
          last_compacted_message_id: assistant_message.id,
          last_compacted_at: now
        )
      end
      true
    rescue StandardError => e
      Rails.logger.warn("Conversation compaction failed chat_session_id=#{chat_session&.id}: #{e.class}: #{e.message}")
      false
    end

    private

    attr_reader :chat_session, :user_message, :assistant_message, :now

    def follow_up?
      @follow_up
    end

    def topic_to_update(extracted_topic, active_topic)
      return active_topic if follow_up? && active_topic.present?
      return extracted_topic if extracted_topic.present?
      return active_topic if text_looks_like_follow_up?(user_message.content) && active_topic.present?

      nil
    end

    def extract_topic(text)
      normalized = normalize(text)
      base_topic = if normalized.match?(FAMILY_TERMS) && normalized.match?(FAMILY_ACTION_TERMS)
        family_topic(normalized)
      elsif normalized.match?(CAR_REPAIR_TERMS)
        simple_topic("car_repair", "Car repair", "car repair")
      elsif normalized.match?(CAR_REGISTRATION_TERMS)
        simple_topic("car_registration", "Car registration", "car registration")
      elsif normalized.match?(JOB_TERMS)
        simple_topic("job_business", "Job or business transition", "job/business decision")
      elsif normalized.match?(DEBT_TERMS)
        simple_topic("debt", "Debt decision", "debt")
      elsif normalized.match?(SINKING_TERMS)
        simple_topic("sinking_fund", sinking_title(normalized), sinking_subject(normalized))
      elsif normalized.match?(PENDING_TERMS)
        simple_topic("pending_drafts", "Pending transaction drafts", "pending drafts")
      elsif transaction_report?(normalized)
        simple_topic("transaction_draft", "Reported spending", merchant_subject(text) || "reported spending")
      elsif normalized.match?(READINESS_TERMS)
        simple_topic("readiness_plan", "Readiness plan", "red/yellow/green plan")
      elsif normalized.match?(PURCHASE_TERMS)
        purchase_topic(text)
      elsif normalized.match?(REPORT_TERMS)
        simple_topic("budget_report", "Budget or spending report", report_subject(normalized))
      end

      add_amount(base_topic)
    end

    def family_topic(normalized)
      member = normalized.match(FAMILY_TERMS)&.[](0)&.titleize || "family"
      simple_topic("family_support", "Family support for #{member}", member.downcase)
    end

    def sinking_title(normalized)
      return "Insurance renewal" if normalized.match?(/insurance|renewal/)
      return "Back-to-school sinking fund" if normalized.match?(/school|uniform/)
      return "Gift sinking fund" if normalized.match?(/gift/)
      return "Unexpected repair sinking fund" if normalized.match?(/fridge|appliance|home repair/)

      "Sinking fund decision"
    end

    def sinking_subject(normalized)
      return "insurance renewal" if normalized.match?(/insurance|renewal/)
      return "school uniforms" if normalized.match?(/school|uniform/)
      return "gifts" if normalized.match?(/gift/)
      return "unexpected repair" if normalized.match?(/fridge|appliance|home repair/)

      "sinking fund"
    end

    def purchase_topic(text)
      subject = purchase_subject(text) || "purchase"
      simple_topic("purchase_decision", "Purchase decision: #{subject}", subject)
    end

    def purchase_subject(text)
      normalized = normalize(text)
      match = normalized.match(/\b(?:buy|purchase|get|order|book|afford|take|go on)\s+(?:these|this|the|a|an|some|we\s+)?\s*([a-z0-9\s-]+?)(?:\s+(?:right now|today|this month|next month|for|because|if)|[?.!]|$)/i)
      match&.[](1)&.squish.presence
    end

    def report_subject(normalized)
      return "Dining Out" if normalized.include?("dining out")
      return "groceries" if normalized.match?(/grocer/)
      return "categories over plan" if normalized.match?(/over plan|over budget/)

      "budget report"
    end

    def merchant_subject(text)
      match = text.match(/\b(?:at|from|to)\s+([^.,;!?$]+?)(?:\s+(?:for|on|today|yesterday)|[.,;!?]|\z)/i)
      match&.[](1)&.squish
    end

    def simple_topic(type, title, subject)
      {
        "id" => SecureRandom.uuid,
        "type" => type,
        "title" => title,
        "subject" => subject,
        "status" => "open",
        "created_at" => now.iso8601
      }
    end

    def add_amount(topic)
      return unless topic

      amount_cents = amount_from_text(user_message.content)
      return topic unless amount_cents&.positive?

      topic.merge(
        "amount_cents" => amount_cents,
        "amount_label" => money(amount_cents)
      )
    end

    def merge_topic(topic, latest_user_text, latest_assistant_text)
      topic = topic.deep_stringify_keys
      amount_cents = amount_from_text(latest_user_text) || topic["amount_cents"]
      topic.merge(
        "id" => topic["id"].presence || SecureRandom.uuid,
        "status" => topic["status"].presence || "open",
        "amount_cents" => amount_cents,
        "amount_label" => amount_cents ? money(amount_cents) : topic["amount_label"],
        "latest_user_context" => sanitized_text(latest_user_text, max_length: MAX_TEXT_LENGTH),
        "latest_mia_summary" => assistant_summary(latest_assistant_text),
        "next_move" => next_move(latest_assistant_text) || topic["next_move"],
        "updated_at" => now.iso8601,
        "turn_count" => topic["turn_count"].to_i + 1
      ).compact
    end

    def upsert_topic(topics, topic)
      existing_index = topics.index { |candidate| same_topic?(candidate, topic) }
      if existing_index
        existing = topics.delete_at(existing_index)
        topic = existing.merge(topic) { |_key, old_value, new_value| new_value.presence || old_value }
      end

      [ topic, *topics ].first(MAX_TOPICS)
    end

    def same_topic?(left, right)
      return true if left["id"].present? && left["id"] == right["id"]

      left["type"] == right["type"] && left["subject"].to_s.casecmp?(right["subject"].to_s)
    end

    def build_summary(topics)
      return nil if topics.empty?

      lines = topics.first(6).map do |topic|
        parts = [ topic["title"], topic["amount_label"], topic["latest_mia_summary"], topic["next_move"] ].compact_blank
        parts.join(" — ")
      end
      sanitized_text("Open conversation topics: #{lines.join(' | ')}", max_length: 1_500)
    end

    def normalized_topics(value)
      Array(value).filter_map { |topic| normalized_topic(topic) }.first(MAX_TOPICS)
    end

    def normalized_topic(value)
      topic = value.to_h.deep_stringify_keys
      return nil if topic.blank? || topic["title"].blank?

      topic
    end

    def text_looks_like_follow_up?(text)
      normalize(text).match?(FOLLOW_UP_PATTERN)
    end

    def transaction_report?(normalized)
      normalized.match?(TRANSACTION_TERMS) && normalized.match?(AMOUNT_PATTERN)
    end

    def amount_from_text(text)
      match = text.to_s.match(AMOUNT_PATTERN)
      return unless match

      Money.cents(match[1].delete(","))
    end

    def assistant_summary(text)
      sanitized_text(text.to_s.split(/(?<=[.!?])\s+/).first, max_length: MAX_TEXT_LENGTH)
    end

    def next_move(text)
      match = text.to_s.match(/(?:Next CFO move|Your next move|Next move):\s*(.+?)(?:\z|\n)/i)
      sanitized_text(match&.[](1), max_length: MAX_TEXT_LENGTH)
    end

    def sanitized_text(value, max_length:)
      value.to_s
        .unicode_normalize(:nfkc)
        .gsub(/[[:cntrl:]]/, " ")
        .gsub(/[<>`]/, "")
        .squish
        .truncate(max_length, omission: "…")
        .presence
    end

    def normalize(value)
      value.to_s.downcase.gsub(/[^a-z0-9\s$.,'-]/, " ").squish
    end

    def money(cents)
      ActiveSupport::NumberHelper.number_to_currency(
        Money.dollars(cents),
        precision: cents.to_i % 100 == 0 ? 0 : 2
      )
    end
  end
end
