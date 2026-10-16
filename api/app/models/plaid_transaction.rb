class PlaidTransaction < ApplicationRecord
  REVIEW_STATUSES = %w[unreviewed drafted ignored].freeze
  # Plaid personal_finance_category mapped onto the movement vocabulary that
  # statement imports use (FinancialSourceEvent::TYPES). Like a statement row,
  # a bank row is spending only when its type is in FinancialSourceEvent::EXPENSE_TYPES,
  # so transfers, card/loan payments, savings or CD deposits and income stay
  # visible in bank activity without becoming spending drafts. Bank fees and
  # interest charges remain spending, exactly as statement fee/interest rows do.
  NON_SPENDING_PRIMARY_TYPES = {
    "TRANSFER_IN" => "transfer",
    "TRANSFER_OUT" => "transfer",
    "LOAN_PAYMENTS" => "debt_payment",
    "LOAN_DISBURSEMENTS" => "transfer",
    "INCOME" => "income"
  }.freeze
  DETAILED_MOVEMENT_TYPES = {
    "TRANSFER_OUT_WITHDRAWAL" => "cash_withdrawal",
    "BANK_FEES_INTEREST_CHARGE" => "interest"
  }.freeze
  # Person-to-person transfers (Venmo, Zelle, Cash App, PayPal) and ATM
  # withdrawals are often real spending, so they stay spending candidates: they
  # stage a draft carrying a "transfer or payment? you decide" note.
  SPENDING_CANDIDATE_DETAILED = %w[TRANSFER_OUT_OTHER_TRANSFER_OUT TRANSFER_OUT_WITHDRAWAL].freeze
  REVIEW_NOTE_TRANSFER_OR_PAYMENT = "Transfer or payment? You decide whether this counts as spending.".freeze
  COUNTED_AS_SPENDING_SQL = "(plaid_transactions.primary_category IS NULL OR UPPER(plaid_transactions.primary_category) NOT IN (:non_spending) OR UPPER(COALESCE(plaid_transactions.detailed_category, '')) IN (:candidates))".freeze

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
  scope :counted_as_spending, -> { where(COUNTED_AS_SPENDING_SQL, non_spending: NON_SPENDING_PRIMARY_TYPES.keys, candidates: SPENDING_CANDIDATE_DETAILED) }
  scope :not_counted_as_spending, -> { where.not(COUNTED_AS_SPENDING_SQL, non_spending: NON_SPENDING_PRIMARY_TYPES.keys, candidates: SPENDING_CANDIDATE_DETAILED) }
  scope :stageable, -> { current_picture.visible.counted_as_spending.where(pending: false, review_status: "unreviewed").where("amount_cents > 0") }

  def self.counted_as_spending_sql
    sanitize_sql_array([ COUNTED_AS_SPENDING_SQL, { non_spending: NON_SPENDING_PRIMARY_TYPES.keys, candidates: SPENDING_CANDIDATE_DETAILED } ])
  end

  def stageable?
    current_financial_picture? && removed_at.nil? && !pending? && amount_cents.positive? && review_status == "unreviewed" && counts_as_spending?
  end

  def counts_as_spending?
    !NON_SPENDING_PRIMARY_TYPES.key?(primary_category.to_s.upcase) || transfer_or_payment_candidate?
  end

  def transfer_or_payment_candidate?
    SPENDING_CANDIDATE_DETAILED.include?(detailed_category.to_s.upcase)
  end

  def review_note
    REVIEW_NOTE_TRANSFER_OR_PAYMENT if transfer_or_payment_candidate?
  end

  def movement_type
    DETAILED_MOVEMENT_TYPES[detailed_category.to_s.upcase] ||
      NON_SPENDING_PRIMARY_TYPES[primary_category.to_s.upcase] ||
      (primary_category.to_s.casecmp?("BANK_FEES") ? "fee" : spending_or_refund_type)
  end

  def current_financial_picture?
    financial_generation == plaid_item.financial_generation && plaid_item.current_financial_picture?
  end

  private

  def spending_or_refund_type
    return "purchase" if amount_cents.to_i.positive?

    primary_category.present? ? "refund" : "unknown"
  end

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
