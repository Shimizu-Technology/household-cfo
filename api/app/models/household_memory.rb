require "digest"
require "json"

class HouseholdMemory < ApplicationRecord
  CATEGORIES = %w[goal preference constraint habit coaching_style follow_up].freeze
  STATUSES = %w[pending_confirmation user_confirmed rejected expired].freeze
  SENSITIVITIES = %w[ordinary sensitive].freeze
  VISIBILITIES = %w[private].freeze
  SOURCE_KINDS = %w[manual_profile mia_command].freeze
  MAX_DISPLAY_LENGTH = 500
  MAX_ACTIVE_CONTEXT = 20
  MAX_STORED_PER_OWNER = 100
  MAX_VISIBLE_LIST = 200

  belongs_to :household
  belongs_to :owner_user, class_name: "User"
  belongs_to :source_chat_message, class_name: "ChatMessage", optional: true

  normalizes :display_value, with: ->(value) { value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish }
  normalizes :request_key, with: ->(value) { value.to_s.strip.presence }

  validates :category, inclusion: { in: CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validates :sensitivity, inclusion: { in: SENSITIVITIES }
  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :source_kind, inclusion: { in: SOURCE_KINDS }
  validates :display_value, presence: true, length: { maximum: MAX_DISPLAY_LENGTH }
  validates :request_key, length: { maximum: 120 }, format: { with: /\A[a-zA-Z0-9][a-zA-Z0-9._:-]*\z/ }, allow_nil: true
  validate :structured_value_is_safe_object
  validate :owner_belongs_to_household
  validate :source_message_belongs_to_owner_session

  scope :visible_to, ->(user) { where(owner_user_id: user.id, visibility: "private") }
  scope :active, -> { where(status: "user_confirmed").where("expires_at IS NULL OR expires_at > ?", Time.current) }
  scope :ordered, -> { order(Arel.sql("CASE category WHEN 'coaching_style' THEN 0 WHEN 'constraint' THEN 1 WHEN 'goal' THEN 2 WHEN 'follow_up' THEN 3 ELSE 4 END"), updated_at: :desc, id: :desc) }

  def active?
    status == "user_confirmed" && (expires_at.nil? || expires_at.future?)
  end

  def as_api_json(viewer:)
    {
      id: id,
      category: category,
      status: status,
      sensitivity: sensitivity,
      visibility: visibility,
      display_value: display_value,
      structured_value: structured_value,
      owned_by_current_user: owner_user_id == viewer.id,
      owner_name: owner_user_id == viewer.id ? "You" : owner_user.full_name,
      source_kind: source_kind,
      confirmation_fingerprint: status == "pending_confirmation" ? confirmation_fingerprint : nil,
      confirmed_at: confirmed_at&.iso8601,
      expires_at: expires_at&.iso8601,
      created_at: created_at&.iso8601,
      updated_at: updated_at&.iso8601
    }
  end

  def confirmation_fingerprint
    payload = {
      "category" => category,
      "display_value" => display_value,
      "sensitivity" => sensitivity,
      "visibility" => visibility,
      "structured_value" => canonicalize(structured_value),
      "expires_at" => expires_at&.utc&.iso8601(6),
      "updated_at" => updated_at&.utc&.iso8601(6)
    }
    Digest::SHA256.hexdigest(JSON.generate(payload).b)
  end

  def confirmation_fingerprint_matches?(candidate)
    candidate = candidate.to_s
    expected = confirmation_fingerprint
    candidate.bytesize == expected.bytesize && ActiveSupport::SecurityUtils.secure_compare(candidate, expected)
  end

  private

  def canonicalize(value)
    case value
    when Hash
      value.keys.map(&:to_s).sort.index_with do |key|
        canonicalize(value.key?(key) ? value[key] : value[key.to_sym])
      end
    when Array
      value.map { |child| canonicalize(child) }
    else
      value
    end
  end

  def structured_value_is_safe_object
    errors.add(:structured_value, "must be an object") unless structured_value.is_a?(Hash)
    errors.add(:structured_value, "is too large") if structured_value.is_a?(Hash) && JSON.generate(structured_value).bytesize > 2_000
  end

  def owner_belongs_to_household
    return if household.blank? || owner_user.blank?
    errors.add(:owner_user, "must belong to this household") unless household.household_memberships.exists?(user_id: owner_user_id)
  end

  def source_message_belongs_to_owner_session
    return if source_chat_message.blank? || household.blank? || owner_user.blank?
    session = source_chat_message.chat_session
    errors.add(:source_chat_message, "must belong to this participant in this household") unless session.household_id == household_id && session.user_id == owner_user_id
  end
end
