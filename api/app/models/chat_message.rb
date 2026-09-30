class ChatMessage < ApplicationRecord
  ROLES = %w[user assistant].freeze
  MAX_USER_CONTENT_LENGTH = 2_000
  MAX_ASSISTANT_CONTENT_LENGTH = 8_000
  MAX_CONTENT_LENGTH = MAX_USER_CONTENT_LENGTH

  belongs_to :chat_session

  validates :role, inclusion: { in: ROLES }
  validates :content, presence: true
  validate :content_length_matches_role
  validate :attachments_are_safe_metadata
  validate :presentation_is_safe_metadata

  def as_api_json(author: nil)
    {
      id: id,
      role: role,
      author: author || (role == "assistant" ? "Mia" : "You"),
      content: content,
      attachments: attachments,
      presentation: presentation,
      created_at: created_at&.iso8601
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
