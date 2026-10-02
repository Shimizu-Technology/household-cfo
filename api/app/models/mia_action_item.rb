class MiaActionItem < ApplicationRecord
  ACTION_TYPES = %w[
    create_category update_category update_allocation archive_category restore_category
    update_setup_value upsert_income_schedule_entry create_income_source update_income_source
    archive_income_source restore_income_source create_income_schedule_entry update_income_schedule_entry
    delete_income_schedule_entry
    create_debt update_debt archive_debt restore_debt update_debt_tracking
    create_account update_account archive_account restore_account link_plaid_account reconcile_plaid_account unlink_plaid_account
    create_goal update_goal archive_goal restore_goal update_runway_policy update_transition_policy update_household_profile confirm_household_setup
  ].freeze

  belongs_to :mia_action_draft, inverse_of: :mia_action_items
  belongs_to :canceled_by_user, class_name: "User", optional: true

  validates :action_type, inclusion: { in: ACTION_TYPES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :label, presence: true, length: { maximum: 240 }
  validate :json_payloads_are_hashes
  validate :operation_identity_is_complete
  validate :source_span_matches_source_text
  validate :dependencies_are_prior_positions
  validate :terminal_state_is_consistent

  private

  def json_payloads_are_hashes
    %i[payload before_snapshot after_snapshot prepared_operation].each do |attribute|
      errors.add(attribute, "must be a JSON object") unless public_send(attribute).is_a?(Hash)
    end
  end

  def operation_identity_is_complete
    values = [ operation_key, operation_version, prepared_operation_fingerprint ]
    return if values.all?(&:blank?) && prepared_operation.blank?
    return if values.all?(&:present?) && prepared_operation.present?

    errors.add(:operation_key, "must be stored with its version and prepared fingerprint")
  end

  def source_span_matches_source_text
    return if source_start.nil? && source_end.nil?
    if source_start.nil? || source_end.nil? || source_text.blank? || source_end <= source_start
      errors.add(:source_text, "must include a complete source span")
    end
  end

  def dependencies_are_prior_positions
    values = Array(dependencies)
    unless values.all? { |value| value.is_a?(Integer) && value >= 0 && value < position } && values.uniq.length == values.length
      errors.add(:dependencies, "must contain unique earlier item positions")
    end
  end

  def terminal_state_is_consistent
    errors.add(:canceled_at, "cannot be set after this step was applied") if applied_at.present? && canceled_at.present?
    errors.add(:canceled_by_user, "must be present when this step is canceled") if canceled_at.present? && canceled_by_user.blank?
    errors.add(:canceled_by_user, "must be blank until this step is canceled") if canceled_at.blank? && canceled_by_user.present?
  end
end
