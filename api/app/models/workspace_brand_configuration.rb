# frozen_string_literal: true

class WorkspaceBrandConfiguration < ApplicationRecord
  belongs_to :coach_workspace, inverse_of: :workspace_brand_configuration
  belongs_to :last_edited_by_user, class_name: "User", inverse_of: :edited_workspace_brand_configurations
  belongs_to :current_published_version, class_name: "WorkspaceBrandVersion", optional: true

  has_many :versions,
    -> { order(:version_number) },
    class_name: "WorkspaceBrandVersion",
    dependent: :restrict_with_exception,
    inverse_of: :workspace_brand_configuration
  has_many :publication_events,
    class_name: "WorkspaceBrandPublicationEvent",
    dependent: :restrict_with_exception,
    inverse_of: :workspace_brand_configuration

  validates :coach_workspace_id, uniqueness: true
  validates :draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validates :preview_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validate :editor_can_edit_workspace, if: :will_save_change_to_last_edited_by_user_id?
  validate :draft_matches_schema
  validate :preview_fields_are_complete
  validate :current_version_belongs_to_configuration

  before_validation :normalize_draft
  before_update :track_draft_revision_and_preview

  def apply_rollback_version!(version, actor:)
    raise ArgumentError, "version must belong to this configuration" unless version.workspace_brand_configuration_id == id

    @force_draft_revision_and_preview_reset = true
    @allow_publisher_as_editor = true
    update!(
      draft_config: version.config.deep_dup,
      current_published_version: version,
      last_edited_by_user: actor
    )
  ensure
    @force_draft_revision_and_preview_reset = false
    @allow_publisher_as_editor = false
  end

  private

  def normalize_draft
    @draft_schema_errors = if (new_record? || will_save_change_to_draft_config?) && !@allow_publisher_as_editor
      Branding::Schema.authoring_errors(draft_config)
    else
      Branding::Schema.errors(draft_config)
    end
    self.draft_config = Branding::Schema.normalize(draft_config) if @draft_schema_errors.empty?
  end

  def editor_can_edit_workspace
    allowed = coach_workspace&.allows?(last_edited_by_user, :edit) ||
      (@allow_publisher_as_editor && coach_workspace&.allows?(last_edited_by_user, :publish))
    errors.add(:last_edited_by_user, "cannot edit this coach workspace") unless allowed
  end

  def draft_matches_schema
    Array(@draft_schema_errors || Branding::Schema.errors(draft_config)).each { |message| errors.add(:draft_config, message) }
  end

  def preview_fields_are_complete
    fields = [ preview_digest, previewed_at, previewed_draft_revision ]
    return if fields.all?(&:blank?) || fields.all?(&:present?)

    errors.add(:preview_digest, "and preview metadata must all be present or all be blank")
  end

  def current_version_belongs_to_configuration
    return if current_published_version.nil? || current_published_version.workspace_brand_configuration == self

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
end
