class HouseholdOperationExecution < ApplicationRecord
  SOURCES = %w[manual mia].freeze

  belongs_to :household
  belongs_to :user
  belongs_to :household_audit_event
  belongs_to :reviewable, polymorphic: true, optional: true

  validates :operation_key, :idempotency_key, :request_fingerprint, presence: true
  validates :operation_version, numericality: { only_integer: true, greater_than: 0 }
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: %w[completed] }
  validates :completed_at, presence: true
  validates :idempotency_key, length: { maximum: 200 }, uniqueness: { scope: :household_id }
  validate :json_values_are_objects
  validate :audit_identity_matches_execution
  validate :actor_belongs_to_household
  validate :reviewable_belongs_to_household

  private

  def json_values_are_objects
    %i[normalized_input before_snapshot predicted_after_snapshot after_snapshot].each do |attribute|
      errors.add(attribute, "must be a JSON object") unless public_send(attribute).is_a?(Hash)
    end
  end

  def audit_identity_matches_execution
    return unless household_audit_event

    errors.add(:household_audit_event, "must belong to the same household") unless household_audit_event.household_id == household_id
    errors.add(:household_audit_event, "must belong to the same user") unless household_audit_event.user_id == user_id
  end

  def actor_belongs_to_household
    return if household.blank? || user.blank?
    return if household.household_memberships.exists?(user_id: user_id)

    errors.add(:user, "must belong to the operation household")
  end

  def reviewable_belongs_to_household
    return unless reviewable.is_a?(MiaActionItem)
    return if reviewable.mia_action_draft.household_id == household_id

    errors.add(:reviewable, "must belong to the operation household")
  end
end
