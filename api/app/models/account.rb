class Account < ApplicationRecord
  include CurrentFinancialPicture
  ACCOUNT_TYPES = %w[checking savings emergency_fund retirement investment property other].freeze
  LIQUID_TYPES = %w[checking savings emergency_fund].freeze
  SIGNED_BALANCE_TYPES = %w[checking savings].freeze
  SOURCE_TYPES = %w[manual_ui mia document_import setup plaid].freeze

  belongs_to :household
  belongs_to :plaid_account, optional: true

  validates :label, presence: true, length: { maximum: 120 }
  validates :account_type, inclusion: { in: ACCOUNT_TYPES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :balance_cents, numericality: { only_integer: true }
  validates :plaid_account_id, uniqueness: true, allow_nil: true
  validate :active_name_is_unique
  validate :archive_state_is_consistent
  validate :balance_state_is_consistent
  validate :negative_balance_is_cash_only
  validate :source_metadata_is_object
  validate :plaid_account_belongs_to_household

  scope :active, -> { where(active: true) }
  scope :archived, -> { where(active: false) }

  def liquid?
    account_type.in?(LIQUID_TYPES)
  end

  private

  def active_name_is_unique
    return unless active? && household_id && label.present? && account_type.present?

    scope = self.class.active.where(household_id: household_id, financial_generation: financial_generation, account_type: account_type)
      .where("LOWER(label) = ?", label.to_s.downcase)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:label, "has already been taken") if scope.exists?
  end

  def archive_state_is_consistent
    errors.add(:archived_at, "must be blank for an active account") if active? && archived_at.present?
    errors.add(:archived_at, "is required for an archived account") unless active? || archived_at.present?
  end

  def balance_state_is_consistent
    return if balance_known?

    errors.add(:balance_cents, "must be zero while the balance is unknown") unless balance_cents.to_i.zero?
    errors.add(:balance_as_of_on, "must be blank while the balance is unknown") if balance_as_of_on.present?
  end

  def negative_balance_is_cash_only
    return unless balance_cents.to_i.negative?
    errors.add(:balance_cents, "cannot be negative for this account type") unless account_type.in?(SIGNED_BALANCE_TYPES)
  end

  def source_metadata_is_object
    errors.add(:source_metadata, "must be an object") unless source_metadata.is_a?(Hash)
  end

  def plaid_account_belongs_to_household
    return unless plaid_account
    errors.add(:plaid_account, "must belong to this household") unless plaid_account.plaid_item.household_id == household_id
  end
end
