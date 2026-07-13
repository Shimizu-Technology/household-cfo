class PlaidAccount < ApplicationRecord
  belongs_to :plaid_item
  has_many :plaid_transactions, dependent: :destroy

  validates :plaid_account_id, :name, :account_type, presence: true
  validates :plaid_account_id, uniqueness: true
  validates :name, :official_name, length: { maximum: 160 }, allow_blank: true
end
