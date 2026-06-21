class User < ApplicationRecord
  ROLES = %w[admin coach participant].freeze
  INVITATION_STATUSES = %w[pending accepted revoked].freeze

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :clerk_id, presence: true, uniqueness: true
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: ROLES }
  validates :invitation_status, inclusion: { in: INVITATION_STATUSES }

  before_validation :set_defaults

  def admin?
    role == "admin"
  end

  def coach?
    role == "coach"
  end

  def participant?
    role == "participant"
  end

  def staff?
    admin? || coach?
  end

  def invitation_pending?
    invitation_status == "pending" || clerk_id.to_s.start_with?("pending_")
  end

  def invitation_accepted?
    invitation_status == "accepted" && clerk_id.present? && !clerk_id.start_with?("pending_")
  end

  def revoked?
    invitation_status == "revoked"
  end

  def full_name
    [ first_name, last_name ].compact_blank.join(" ").presence || email.to_s.split("@").first
  end

  def as_api_json
    {
      id: id,
      clerk_id: clerk_id,
      email: email,
      first_name: first_name,
      last_name: last_name,
      full_name: full_name,
      role: role,
      invitation_status: invitation_status,
      invited_at: invited_at,
      accepted_at: accepted_at,
      last_sign_in_at: last_sign_in_at,
      created_at: created_at,
      is_admin: admin?,
      is_coach: coach?,
      is_participant: participant?,
      is_staff: staff?
    }
  end

  private

  def set_defaults
    self.role ||= "participant"
    self.invitation_status ||= "accepted"
  end
end
