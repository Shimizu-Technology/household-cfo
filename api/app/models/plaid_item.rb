class PlaidItem < ApplicationRecord
  STATUSES = %w[active update_required error disconnected].freeze
  ENVIRONMENTS = %w[sandbox production].freeze

  belongs_to :household
  belongs_to :connected_by_user, class_name: "User"
  has_many :plaid_accounts, dependent: :destroy
  has_many :plaid_transactions, dependent: :destroy

  validates :plaid_item_id, presence: true, uniqueness: true
  validates :environment, inclusion: { in: ENVIRONMENTS }
  validates :status, inclusion: { in: STATUSES }
  validates :consented_at, :consent_policy_version, presence: true
  validates :access_token_ciphertext, presence: true, unless: -> { status == "disconnected" }
  validates :institution_name, length: { maximum: 160 }, allow_blank: true

  scope :connected, -> { where.not(status: "disconnected") }

  def access_token
    return if access_token_ciphertext.blank?

    PlaidIntegration::TokenEncryptor.decrypt(access_token_ciphertext)
  end

  def access_token=(value)
    self.access_token_ciphertext = value.present? ? PlaidIntegration::TokenEncryptor.encrypt(value) : nil
  end

  def connected?
    status != "disconnected"
  end
end
