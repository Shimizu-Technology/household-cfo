class PlaidTransaction < ApplicationRecord
  REVIEW_STATUSES = %w[unreviewed drafted ignored].freeze

  belongs_to :plaid_item
  belongs_to :plaid_account
  belongs_to :transaction_draft, optional: true

  before_validation :stamp_financial_generation, on: :create

  validates :plaid_transaction_id, :name, :occurred_on, presence: true
  validates :source_fingerprint, presence: true
  validates :plaid_transaction_id, uniqueness: true
  validates :amount_cents, numericality: { only_integer: true }
  validates :review_status, inclusion: { in: REVIEW_STATUSES }
  validates :name, :merchant_name, length: { maximum: 160 }, allow_blank: true
  validate :associations_belong_to_plaid_item

  scope :current_picture, -> { joins(:plaid_item).where("plaid_transactions.financial_generation = plaid_items.financial_generation AND plaid_items.financial_generation = (SELECT financial_generation FROM households WHERE households.id = plaid_items.household_id)") }

  scope :visible, -> { where(removed_at: nil) }
  scope :recent_first, -> { order(occurred_on: :desc, id: :desc) }
  scope :stageable, -> { current_picture.visible.where(pending: false, review_status: "unreviewed").where("amount_cents > 0") }

  def stageable?
    current_financial_picture? && removed_at.nil? && !pending? && amount_cents.positive? && review_status == "unreviewed"
  end

  def current_financial_picture?
    financial_generation == plaid_item.financial_generation && plaid_item.current_financial_picture?
  end

  private

  def stamp_financial_generation
    self.financial_generation = plaid_item.financial_generation
  end

  def associations_belong_to_plaid_item
    errors.add(:plaid_account, "must belong to the selected bank connection") if plaid_account && plaid_account.plaid_item_id != plaid_item_id
    return if transaction_draft.blank? || plaid_item.blank?
    return if transaction_draft.household_id == plaid_item.household_id

    errors.add(:transaction_draft, "must belong to the bank connection household")
  end
end
