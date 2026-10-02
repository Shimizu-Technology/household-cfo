class MiaActionDraftApplication < ApplicationRecord
  STATUSES = %w[processing completed failed].freeze
  REQUEST_KINDS = %w[apply cancel].freeze

  belongs_to :mia_action_draft
  belongs_to :household
  belongs_to :user

  validates :idempotency_key, presence: true, length: { maximum: 200 }
  validates :request_fingerprint, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :request_kind, inclusion: { in: REQUEST_KINDS }
  validate :selected_item_ids_are_positive_integers
  validate :draft_belongs_to_household

  private

  def selected_item_ids_are_positive_integers
    values = Array(selected_item_ids)
    errors.add(:selected_item_ids, "must contain unique positive integers") unless
      values.all? { |value| value.is_a?(Integer) && value.positive? } && values.uniq.length == values.length
  end

  def draft_belongs_to_household
    errors.add(:mia_action_draft, "must belong to the same household") if mia_action_draft && mia_action_draft.household_id != household_id
  end
end
