class MiaActionItem < ApplicationRecord
  ACTION_TYPES = %w[create_category update_category update_allocation archive_category restore_category].freeze

  belongs_to :mia_action_draft, inverse_of: :mia_action_items

  validates :action_type, inclusion: { in: ACTION_TYPES }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :label, presence: true, length: { maximum: 240 }
  validate :json_payloads_are_hashes

  private

  def json_payloads_are_hashes
    %i[payload before_snapshot after_snapshot].each do |attribute|
      errors.add(attribute, "must be a JSON object") unless public_send(attribute).is_a?(Hash)
    end
  end
end
