class User < ApplicationRecord
  ROLES = %w[admin coach participant].freeze
  INVITATION_STATUSES = %w[pending accepted revoked].freeze
  INVITATION_EMAIL_STATUSES = %w[not_sent skipped sent failed].freeze

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :clerk_id, presence: true, uniqueness: true
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :role, inclusion: { in: ROLES }
  validates :invitation_status, inclusion: { in: INVITATION_STATUSES }
  validates :invitation_email_status, inclusion: { in: INVITATION_EMAIL_STATUSES }, allow_nil: true

  belongs_to :invited_by_user, class_name: "User", optional: true
  belongs_to :last_invite_email_sent_by_user, class_name: "User", optional: true

  has_many :invited_users, class_name: "User", foreign_key: :invited_by_user_id, dependent: :nullify, inverse_of: :invited_by_user
  has_many :sent_invite_emails, class_name: "User", foreign_key: :last_invite_email_sent_by_user_id, dependent: :nullify, inverse_of: :last_invite_email_sent_by_user
  has_many :invitation_email_attempts, dependent: :destroy
  has_many :sent_invitation_email_attempts, class_name: "InvitationEmailAttempt", foreign_key: :sent_by_user_id, dependent: :nullify, inverse_of: :sent_by_user
  has_many :household_memberships, dependent: :destroy
  has_many :households, through: :household_memberships
  has_many :created_households, class_name: "Household", foreign_key: :created_by_user_id, dependent: :restrict_with_exception, inverse_of: :created_by_user
  has_many :cohorts_created, class_name: "Cohort", foreign_key: :created_by_user_id, dependent: :restrict_with_exception, inverse_of: :created_by_user
  has_many :created_coach_personas, class_name: "CoachPersona", foreign_key: :created_by_user_id, dependent: :restrict_with_exception, inverse_of: :created_by_user
  has_many :published_coach_persona_versions, class_name: "CoachPersonaVersion", foreign_key: :published_by_user_id, dependent: :restrict_with_exception, inverse_of: :published_by_user
  has_many :coach_persona_publication_events, foreign_key: :actor_user_id, dependent: :restrict_with_exception, inverse_of: :actor_user
  has_many :created_coach_content_items, class_name: "CoachContentItem", foreign_key: :created_by_user_id, dependent: :restrict_with_exception, inverse_of: :created_by_user
  has_many :approved_coach_content_item_versions, class_name: "CoachContentItemVersion", foreign_key: :approved_by_user_id, dependent: :restrict_with_exception, inverse_of: :approved_by_user
  has_many :created_coach_content_packs, class_name: "CoachContentPack", foreign_key: :created_by_user_id, dependent: :restrict_with_exception, inverse_of: :created_by_user
  has_many :published_coach_content_pack_versions, class_name: "CoachContentPackVersion", foreign_key: :published_by_user_id, dependent: :restrict_with_exception, inverse_of: :published_by_user
  has_many :cohort_persona_assignments, foreign_key: :assigned_by_user_id, dependent: :restrict_with_exception, inverse_of: :assigned_by_user
  has_many :edited_cohort_experience_configurations, class_name: "CohortExperienceConfiguration", foreign_key: :last_edited_by_user_id, dependent: :restrict_with_exception, inverse_of: :last_edited_by_user
  has_many :published_cohort_experience_versions, class_name: "CohortExperienceVersion", foreign_key: :published_by_user_id, dependent: :restrict_with_exception, inverse_of: :published_by_user
  has_many :cohort_experience_publication_events, foreign_key: :actor_user_id, dependent: :restrict_with_exception, inverse_of: :actor_user
  has_many :cohort_memberships, dependent: :destroy
  has_many :cohorts, through: :cohort_memberships
  has_many :coach_workspace_memberships, dependent: :restrict_with_exception, inverse_of: :user
  has_many :coach_workspaces, through: :coach_workspace_memberships
  has_many :created_coach_workspaces, class_name: "CoachWorkspace", foreign_key: :created_by_user_id,
    dependent: :restrict_with_exception, inverse_of: :created_by_user
  has_many :chat_sessions, dependent: :destroy
  has_many :uploaded_financial_document_imports, class_name: "FinancialDocumentImport", foreign_key: :uploaded_by_user_id, dependent: :restrict_with_exception, inverse_of: :uploaded_by_user
  has_many :applied_financial_document_imports, class_name: "FinancialDocumentImport", foreign_key: :applied_by_user_id, dependent: :nullify, inverse_of: :applied_by_user
  has_many :source_deleted_financial_document_imports, class_name: "FinancialDocumentImport", foreign_key: :source_deleted_by_user_id, dependent: :nullify, inverse_of: :source_deleted_by_user
  has_many :applied_financial_document_import_items, class_name: "FinancialDocumentImportItem", foreign_key: :applied_by_user_id, dependent: :nullify, inverse_of: :applied_by_user
  has_many :pilot_feedback_reports, dependent: :destroy
  has_many :owned_household_memories, class_name: "HouseholdMemory", foreign_key: :owner_user_id, dependent: :destroy, inverse_of: :owner_user

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

  def as_api_json(active_coach_workspace: nil)
    payload = {
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
    if staff?
      memberships_by_workspace_id = coach_workspace_memberships.to_a.index_by(&:coach_workspace_id)
      workspaces = CoachWorkspace.visible_to(self).includes(:coach_profile).order(:name, :id)
      payload[:coach_workspaces] = workspaces.map do |workspace|
        workspace.as_api_json(user: self, membership: memberships_by_workspace_id[workspace.id])
      end
      payload[:active_coach_workspace] = active_coach_workspace&.as_api_json(
        user: self,
        membership: memberships_by_workspace_id[active_coach_workspace.id]
      )
    end
    payload
  end

  private

  def set_defaults
    self.role ||= "participant"
    self.invitation_status ||= "accepted"
    self.invitation_email_status ||= "not_sent"
  end
end
