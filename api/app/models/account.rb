class Account < ApplicationRecord
  ACCOUNT_TYPES = %w[checking savings emergency_fund retirement investment property other].freeze
  LIQUID_TYPES = %w[checking savings emergency_fund].freeze

  belongs_to :household

  validates :label, presence: true, uniqueness: { scope: [ :household_id, :account_type ] }
  validates :account_type, inclusion: { in: ACCOUNT_TYPES }
  validates :balance_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def liquid?
    account_type.in?(LIQUID_TYPES)
  end
end
