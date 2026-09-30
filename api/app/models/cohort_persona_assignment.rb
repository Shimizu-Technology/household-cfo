# frozen_string_literal: true

class CohortPersonaAssignment < ApplicationRecord
  belongs_to :cohort, inverse_of: :cohort_persona_assignment
  belongs_to :coach_persona, inverse_of: :cohort_persona_assignments
  belongs_to :coach_persona_version, inverse_of: :cohort_persona_assignments
  belongs_to :assigned_by_user, class_name: "User", inverse_of: :cohort_persona_assignments

  validates :cohort_id, uniqueness: true
  validate :assigner_is_staff
  validate :persona_has_published_version
  validate :version_is_current_for_persona

  before_validation :assign_current_version, on: :create

  private

  def assign_current_version
    self.coach_persona_version ||= coach_persona&.current_published_version
  end

  def assigner_is_staff
    errors.add(:assigned_by_user, "must be a coach or admin") unless assigned_by_user&.staff?
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
