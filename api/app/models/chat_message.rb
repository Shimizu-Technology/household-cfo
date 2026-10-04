class ChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze
  MAX_USER_CONTENT_LENGTH = 8_000
  MAX_ASSISTANT_CONTENT_LENGTH = 8_000
  MAX_CONTENT_LENGTH = MAX_USER_CONTENT_LENGTH

  belongs_to :chat_session
  belongs_to :coach_persona_version, optional: true, inverse_of: :chat_messages
  belongs_to :cohort, optional: true
  belongs_to :cohort_release, optional: true
  has_many :coach_content_citations, -> { order(:rank) }, dependent: :delete_all

  normalizes :assistant_author, with: ->(value) { value.to_s.strip.presence }

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true
  validate :content_length_matches_role
  validate :attachments_are_safe_metadata
  validate :presentation_is_safe_metadata
  validate :persona_attribution_is_complete
  validate :persona_attribution_is_immutable, on: :update
  validate :release_attribution_is_complete
  validate :session_program_matches

  before_validation :set_global_assistant_author, on: :create

  def as_api_json(author: nil)
    citations = if association(:coach_content_citations).loaded?
      coach_content_citations.target.sort_by(&:rank)
    else
      coach_content_citations.includes(:coach_content_pack_version, coach_content_item_version: :coach_content_item).to_a
    end

    {
      id: id,
      role: role,
      author: author || (role == "assistant" ? assistant_author.presence || "Mia" : "You"),
      content: content,
      attachments: attachments,
      presentation: presentation,
      citations: citations.map do |citation|
        item_version = citation.coach_content_item_version
        {
          title: item_version.title,
          kind: item_version.kind,
          item_version: item_version.version_number,
          pack_name: citation.coach_content_pack_version.name,
          pack_version: citation.coach_content_pack_version.version_number,
          reason: citation.reason
        }
      end,
      created_at: created_at&.iso8601,
      cohort_id: cohort_id,
      cohort_release_id: cohort_release_id
    }
  end

  private

  def content_length_matches_role
    maximum = role == "assistant" ? MAX_ASSISTANT_CONTENT_LENGTH : MAX_USER_CONTENT_LENGTH
    errors.add(:content, "is too long (maximum is #{maximum} characters)") if content.to_s.length > maximum
  end

  def attachments_are_safe_metadata
    return if attachments.is_a?(Array) && attachments.length <= 5

    errors.add(:attachments, "must be an array of up to 5 files")
  end

  def persona_attribution_is_complete
    if coach_persona_version_id.blank? && assistant_author.blank?
      return
    end
    unless role == "assistant"
      errors.add(:assistant_author, "and persona version are available only on assistant messages")
      return
    end

    errors.add(:assistant_author, "is required when a persona version is set") if coach_persona_version_id.present? && assistant_author.blank?

    errors.add(:assistant_author, "is too long (maximum is 80 characters)") if assistant_author.to_s.length > 80
  end

  def persona_attribution_is_immutable
    return unless will_save_change_to_role? || will_save_change_to_assistant_author? ||
      will_save_change_to_coach_persona_version_id? || will_save_change_to_cohort_id? ||
      will_save_change_to_cohort_release_id? || will_save_change_to_chat_session_id?

    errors.add(:base, "message role and assistant attribution are immutable")
  end

  def session_program_matches
    return unless chat_session&.cohort_id
    unless cohort_id == chat_session.cohort_id && cohort_release&.cohort_id == cohort_id && cohort_release.tool_registry_version >= 3 &&
        cohort_release.experience_snapshot.dig("config", "experience_mode") == "savings_challenge"
      errors.add(:base, "message must match its sealed challenge conversation")
    end
  end

  def release_attribution_is_complete
    return if cohort_id.blank? && cohort_release_id.blank?
    if cohort_id.blank?
      errors.add(:cohort, "is required when a release is attributed")
      return
    end
    return if cohort_release_id.blank?
    return if cohort_release&.cohort_id == cohort_id

    errors.add(:cohort_release, "must belong to the attributed cohort")
  end

  def set_global_assistant_author
    self.assistant_author = "Mia" if role == "assistant" && coach_persona_version_id.nil? && assistant_author.blank?
  end

  def presentation_is_safe_metadata
    return if presentation == {}
    return errors.add(:presentation, "is available only for assistant messages") unless role == "assistant"
    return errors.add(:presentation, "must be an object") unless presentation.is_a?(Hash)

    payload = presentation.deep_stringify_keys
    sections = payload["sections"]
    valid = valid_presentation_keys?(payload) &&
      payload["version"] == 1 && payload["kind"] == "read_only_answer" &&
      payload["basis"].in?(%w[saved_household saved_household_plus_scenario scenario_only]) &&
      payload["lead"].is_a?(String) && payload["lead"].length <= 500 &&
      sections.is_a?(Array) && sections.length.between?(1, 6) &&
      sections.all? { |section| valid_presentation_section?(section) } &&
      valid_presentation_scenario?(payload["scenario"]) &&
      JSON.generate(payload).bytesize <= MAX_ASSISTANT_CONTENT_LENGTH
    errors.add(:presentation, "is not a supported Mia presentation") unless valid
  end

  def valid_presentation_keys?(payload)
    payload.keys.sort.in?([
      %w[basis kind lead sections version],
      %w[basis kind lead scenario sections version]
    ])
  end

  def valid_presentation_section?(section)
    section.is_a?(Hash) && section.keys.map(&:to_s).sort == %w[body id title] &&
      section["id"].to_s.match?(/\Apart-[1-6]\z/) && section["title"].is_a?(String) &&
      section["title"].length.between?(1, 120) && section["body"].is_a?(String) &&
      section["body"].length.between?(1, 2_000)
  end

  def valid_presentation_scenario?(scenario)
    return true if scenario.nil?
    return false unless scenario.is_a?(Hash) && scenario.keys.map(&:to_s) == [ "values" ]

    values = scenario["values"]
    values.is_a?(Array) && values.length.between?(1, 6) && values.all? do |value|
      value.is_a?(Hash) && value.keys.map(&:to_s).sort == %w[display_value label] &&
        value["label"].is_a?(String) && value["label"].length.between?(1, 120) &&
        value["display_value"].is_a?(String) && value["display_value"].length.between?(1, 80)
    end
  end
end
