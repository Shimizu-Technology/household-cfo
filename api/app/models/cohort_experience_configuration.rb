# frozen_string_literal: true

class CohortExperienceConfiguration < ApplicationRecord
  belongs_to :cohort, inverse_of: :cohort_experience_configuration
  belongs_to :coach_workspace
  belongs_to :last_edited_by_user, class_name: "User", inverse_of: :edited_cohort_experience_configurations
  belongs_to :current_published_version, class_name: "CohortExperienceVersion", optional: true

  has_many :versions,
    -> { order(:version_number) },
    class_name: "CohortExperienceVersion",
    dependent: :restrict_with_exception,
    inverse_of: :cohort_experience_configuration
  has_many :publication_events,
    class_name: "CohortExperiencePublicationEvent",
    dependent: :restrict_with_exception,
    inverse_of: :cohort_experience_configuration

  validates :cohort_id, uniqueness: true
  validates :draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :preview_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :editor_is_staff, if: :will_save_change_to_last_edited_by_user_id?
  validate :draft_matches_schema
  validate :preview_fields_are_complete
  validate :current_version_belongs_to_configuration
  validate :workspace_matches_cohort

  before_validation :assign_coach_workspace
  before_validation :normalize_draft
  before_update :track_draft_revision_and_preview

  private

  def normalize_draft
    @draft_schema_errors = CohortExperience::Schema.errors(draft_config)
    self.draft_config = CohortExperience::Schema.normalize(draft_config) if @draft_schema_errors.empty?
  end

  def assign_coach_workspace
    self.coach_workspace ||= cohort&.coach_workspace
  end

  def workspace_matches_cohort
    return if cohort.nil? || coach_workspace_id == cohort.coach_workspace_id

    errors.add(:coach_workspace, "must match the cohort")
  end

  def editor_is_staff
    errors.add(:last_edited_by_user, "cannot edit this coach workspace") unless coach_workspace&.allows?(last_edited_by_user, :edit)
  end

  def draft_matches_schema
    Array(@draft_schema_errors || CohortExperience::Schema.errors(draft_config)).each { |message| errors.add(:draft_config, message) }
  end

  def preview_fields_are_complete
    fields = [ preview_digest, previewed_at, previewed_draft_revision ]
    return if fields.all?(&:blank?) || fields.all?(&:present?)

    errors.add(:preview_digest, "and preview metadata must all be present or all be blank")
  end

  def current_version_belongs_to_configuration
    return if current_published_version.nil? || current_published_version.cohort_experience_configuration == self

    errors.add(:current_published_version, "must belong to this configuration")
  end

  def track_draft_revision_and_preview
    unless will_save_change_to_draft_config? || @force_draft_revision_and_preview_reset
      self.draft_revision = draft_revision_was
      return
    end

    self.draft_revision = draft_revision_was + 1
    self.preview_digest = nil
    self.previewed_at = nil
    self.previewed_draft_revision = nil
  end

  public

  def apply_rollback_version!(version, actor:)
    raise ArgumentError, "version must belong to this configuration" unless version.cohort_experience_configuration_id == id

    @force_draft_revision_and_preview_reset = true
    update!(
      draft_config: version.config.deep_dup,
      current_published_version: version,
      last_edited_by_user: actor
    )
  ensure
    @force_draft_revision_and_preview_reset = false
  end
end
