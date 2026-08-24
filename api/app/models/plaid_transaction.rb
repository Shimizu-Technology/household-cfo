class PlaidTransaction < ApplicationRecord
  REVIEW_STATUSES = %w[unreviewed drafted ignored].freeze

  belongs_to :plaid_item
  belongs_to :plaid_account
  belongs_to :transaction_draft, optional: true

  validates :plaid_transaction_id, :name, :occurred_on, presence: true
  validates :source_fingerprint, presence: true
  validates :plaid_transaction_id, uniqueness: true
  validates :amount_cents, numericality: { only_integer: true }
  validates :review_status, inclusion: { in: REVIEW_STATUSES }
  validates :name, :merchant_name, length: { maximum: 160 }, allow_blank: true
  validate :associations_belong_to_plaid_item

  scope :visible, -> { where(removed_at: nil) }
  scope :recent_first, -> { order(occurred_on: :desc, id: :desc) }
  scope :stageable, -> { visible.where(pending: false, review_status: "unreviewed").where("amount_cents > 0") }

  def stageable?
    removed_at.nil? && !pending? && amount_cents.positive? && review_status == "unreviewed"
  end

  private

  def associations_belong_to_plaid_item
    errors.add(:plaid_account, "must belong to the selected bank connection") if plaid_account && plaid_account.plaid_item_id != plaid_item_id
    return if transaction_draft.blank? || plaid_item.blank?
    return if transaction_draft.household_id == plaid_item.household_id

    errors.add(:transaction_draft, "must belong to the bank connection household")
  end
end
