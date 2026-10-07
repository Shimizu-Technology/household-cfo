class AuthenticationIdentity < ApplicationRecord
  belongs_to :user

  validates :provider, inclusion: { in: %w[clerk workos] }
  validates :issuer, :subject, presence: true
  validates :subject, uniqueness: { scope: [ :provider, :issuer ] }
  validates :user_id, uniqueness: { scope: [ :provider, :issuer ] }
end
