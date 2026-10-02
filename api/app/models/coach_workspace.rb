# frozen_string_literal: true

class CoachWorkspace < ApplicationRecord
  PERMISSIONS = {
    "owner" => %i[view edit review publish assign manage_members],
    "editor" => %i[view edit],
    "reviewer" => %i[view review publish assign],
    "viewer" => %i[view]
  }.freeze

  belongs_to :created_by_user, class_name: "User"
  has_one :coach_profile, dependent: :destroy, inverse_of: :coach_workspace
  has_many :coach_workspace_memberships, dependent: :destroy, inverse_of: :coach_workspace
  has_many :members, through: :coach_workspace_memberships, source: :user
  has_many :cohorts, dependent: :restrict_with_exception
  has_many :coach_personas, dependent: :restrict_with_exception
  has_many :cohort_releases, dependent: :restrict_with_exception
  has_many :coach_operation_executions, dependent: :restrict_with_exception
  has_many :coach_content_sources, dependent: :restrict_with_exception
  has_many :coach_content_items, dependent: :restrict_with_exception
  has_many :coach_content_packs, dependent: :restrict_with_exception
  has_many :coach_phrase_proposals, dependent: :restrict_with_exception
  has_many :coach_persona_evaluation_cases, dependent: :restrict_with_exception

  normalizes :name, with: ->(value) { value.to_s.squish }
  normalizes :slug, with: ->(value) { value.to_s.strip.downcase }

  validates :name, presence: true, length: { maximum: 160 }
  validates :slug, presence: true, length: { maximum: 100 },
    format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }, uniqueness: { case_sensitive: false }

  scope :visible_to, ->(user) {
    if user&.admin?
      all
    else
      joins(:coach_workspace_memberships)
        .where(coach_workspace_memberships: { user_id: user&.id })
        .distinct
    end
  }

  def membership_for(user)
    return nil unless user

    association = association(:coach_workspace_memberships)
    return association.target.find { |membership| membership.user_id == user.id } if association.loaded?

    association.scope.find_by(user_id: user.id)
  end

  def allows?(user, permission)
    return true if user&.admin?

    role = membership_for(user)&.role
    PERMISSIONS.fetch(role, []).include?(permission.to_sym)
  end

  def as_api_json(user:, membership: membership_for(user))
    {
      id: id,
      name: name,
      slug: slug,
      membership_role: user&.admin? ? "platform_admin" : membership&.role,
      coach_profile: coach_profile && {
        display_name: coach_profile.display_name,
        title: coach_profile.title,
        bio: coach_profile.bio.to_s
      }
    }
  end
end
