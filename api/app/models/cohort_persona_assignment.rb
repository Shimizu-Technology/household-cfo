# frozen_string_literal: true

class CohortPersonaAssignment < ApplicationRecord
  belongs_to :cohort, inverse_of: :cohort_persona_assignment
  belongs_to :coach_workspace
  belongs_to :coach_persona, inverse_of: :cohort_persona_assignments
  belongs_to :coach_persona_version, inverse_of: :cohort_persona_assignments
  belongs_to :assigned_by_user, class_name: "User", inverse_of: :cohort_persona_assignments

  validates :cohort_id, uniqueness: true
  validate :assigner_is_staff
  validate :persona_has_published_version
  validate :version_is_current_for_persona
  validate :workspace_boundary_is_consistent

  before_validation :assign_coach_workspace
  before_validation :assign_current_version, on: :create

  private

  def assign_current_version
    self.coach_persona_version ||= coach_persona&.current_published_version
  end

  def assign_coach_workspace
    self.coach_workspace ||= cohort&.coach_workspace
  end

  def workspace_boundary_is_consistent
    errors.add(:coach_workspace, "must match the cohort") if cohort && coach_workspace_id != cohort.coach_workspace_id
    if coach_persona && coach_workspace_id != coach_persona.coach_workspace_id
      errors.add(:coach_persona, "must belong to the same coach workspace")
    end
  end

  def assigner_is_staff
    errors.add(:assigned_by_user, "cannot assign personas in this coach workspace") unless coach_workspace&.allows?(assigned_by_user, :assign)
  end

  def persona_has_published_version
    published_version_id, archived_at = CoachPersona.where(id: coach_persona_id).pick(:current_published_version_id, :archived_at)
    return if published_version_id.present? && archived_at.nil?

    errors.add(:coach_persona, "must be active and published before assignment")
  end

  def version_is_current_for_persona
    return if coach_persona.nil? || coach_persona_version.nil?
    current_version_id = CoachPersona.where(id: coach_persona_id).pick(:current_published_version_id)
    return if current_version_id == coach_persona_version_id

    errors.add(:coach_persona_version, "must be the persona's current published version")
  end
end
