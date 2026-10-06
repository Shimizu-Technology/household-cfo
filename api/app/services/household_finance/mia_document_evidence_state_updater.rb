# frozen_string_literal: true

require "securerandom"

module HouseholdFinance
  class MiaDocumentEvidenceStateUpdater
    MAX_TOPICS = 8
    MAX_TEXT_LENGTH = 240

    def initialize(chat_session, document_imports:, user_message:, assistant_message:, query_scope: nil, activate: true,
      persona_context_id: PersonaVersionedContinuity::UNFILTERED_PERSONA_VERSION)
      @chat_session = chat_session
      @document_imports = Array(document_imports).first(DocumentEvidenceContinuity::MAX_IMPORTS)
      @user_message = user_message
      @assistant_message = assistant_message
      @query_scope = query_scope
      @activate = activate
      @persona_context_id = persona_context_id
    end

    def call
      return false unless chat_session && user_message && assistant_message

      evidence = DocumentEvidenceContinuity.payload(
        {
          schema_version: DocumentEvidenceContinuity::EVIDENCE_SCHEMA_VERSION,
          financial_document_import_ids: document_imports.map(&:id),
          query_scope: query_scope
        },
        household: chat_session.household
      )
      return false unless evidence

      chat_session.with_financial_picture_lock do
        generation = Household.where(id: chat_session.household_id).pick(:financial_generation)
        return false unless user_message.financial_generation == generation && assistant_message.financial_generation == generation
        topics = normalized_topics(chat_session.open_topics)
        previous = topics.find { |topic| DocumentEvidenceContinuity.topic?(topic) }
        topic = evidence_topic(evidence, previous)
        topics.reject! { |candidate| DocumentEvidenceContinuity.topic?(candidate) }
        topics = [ topic, *topics ].first(MAX_TOPICS)
        active = activate ? topic : normalized_topic(chat_session.active_topic)

        chat_session.update!(
          active_topic: active.presence || {},
          open_topics: topics,
          rolling_summary: build_summary(topics),
          last_compacted_message_id: assistant_message.id,
          last_compacted_at: Time.current
        )
      end
      true
    rescue StandardError => error
      Rails.logger.warn("Mia document evidence state update failed chat_session_id=#{chat_session&.id}: #{error.class}: #{error.message}")
      false
    end

    def self.retire(chat_session, persona_context_id: PersonaVersionedContinuity::UNFILTERED_PERSONA_VERSION)
      return false unless chat_session

      new(chat_session, document_imports: [], user_message: nil, assistant_message: nil, persona_context_id: persona_context_id)
        .send(:retire)
    end

    private

    attr_reader :chat_session, :document_imports, :user_message, :assistant_message, :query_scope, :activate, :persona_context_id

    def retire
      chat_session.with_financial_picture_lock do
        topics = normalized_topics(chat_session.open_topics).reject { |topic| DocumentEvidenceContinuity.topic?(topic) }
        active = normalized_topic(chat_session.active_topic)
        active = {} if DocumentEvidenceContinuity.topic?(active)
        chat_session.update!(active_topic: active.presence || {}, open_topics: topics, rolling_summary: build_summary(topics))
      end
      true
    rescue StandardError => error
      Rails.logger.warn("Mia document evidence retirement failed chat_session_id=#{chat_session&.id}: #{error.class}: #{error.message}")
      false
    end

    def evidence_topic(evidence, previous)
      topic = {
        "schema_version" => DocumentEvidenceContinuity::TOPIC_SCHEMA_VERSION,
        "id" => previous&.fetch("id", nil).presence || SecureRandom.uuid,
        "type" => "document_evidence",
        "title" => document_imports.one? ? "Prior upload" : "Prior uploads",
        "subject" => "uploaded financial documents",
        "status" => "open",
        "latest_user_context" => bounded(user_message.content),
        "latest_mia_summary" => bounded(assistant_message.content),
        "document_evidence" => evidence,
        "updated_at" => Time.current.iso8601
      }
      PersonaVersionedContinuity.stamp_assistant_context(
        topic,
        persona_context_id: persona_context_id,
        persona_version_id: assistant_message.coach_persona_version_id
      )
    end

    def normalized_topics(value)
      Array(value).filter_map { |topic| normalized_topic(topic) }.first(MAX_TOPICS)
    end

    def normalized_topic(value)
      topic = PersonaVersionedContinuity.filter_topic(value, persona_context_id: persona_context_id)
      topic = DocumentEvidenceContinuity.sanitize_topic(topic, household: chat_session.household)
      return nil if topic.blank? || topic["title"].blank?

      topic
    end

    def build_summary(topics)
      return nil if topics.empty?

      lines = topics.first(6).map do |topic|
        [ topic["title"], topic["subject"], topic["status"], topic["latest_mia_summary"] ].compact_blank.join(" — ")
      end
      bounded("Open conversation threads: #{lines.join(' | ')}", 1_500)
    end

    def bounded(value, limit = MAX_TEXT_LENGTH)
      value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").gsub(/[<>`]/, "").squish.truncate(limit, omission: "…").presence
    end
  end
end
