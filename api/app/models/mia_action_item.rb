class MiaActionItem < ApplicationRecord
  ACTION_TYPES = %w[
    create_category update_category update_allocation archive_category restore_category
    update_setup_value upsert_income_schedule_entry create_income_source update_income_source
    archive_income_source restore_income_source create_income_schedule_entry update_income_schedule_entry
    delete_income_schedule_entry
    create_debt update_debt archive_debt restore_debt update_debt_tracking
    create_account update_account archive_account restore_account link_plaid_account reconcile_plaid_account unlink_plaid_account
  ].freeze

  belongs_to :mia_action_draft, inverse_of: :mia_action_items

  validates :action_type, inclusion: { in: ACTION_TYPES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :label, presence: true, length: { maximum: 240 }
  validate :json_payloads_are_hashes
  validate :operation_identity_is_complete

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
end
