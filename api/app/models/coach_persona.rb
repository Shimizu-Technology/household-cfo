# frozen_string_literal: true

class CoachPersona < ApplicationRecord
  class DraftConflict < StandardError; end
  class ContentPackSelectionError < ArgumentError; end

  LIVE_COHORT_STATUSES = %w[draft enrolling active].freeze

  scope :active, -> { where(archived_at: nil) }
  scope :archived, -> { where.not(archived_at: nil) }

  belongs_to :created_by_user, class_name: "User", inverse_of: :created_coach_personas
  belongs_to :current_published_version, class_name: "CoachPersonaVersion", optional: true

  has_many :versions,
    -> { order(:version_number) },
    class_name: "CoachPersonaVersion",
    dependent: :restrict_with_exception,
    inverse_of: :coach_persona
  has_many :publication_events, class_name: "CoachPersonaPublicationEvent", dependent: :restrict_with_exception, inverse_of: :coach_persona
  has_many :cohort_persona_assignments, dependent: :restrict_with_exception, inverse_of: :coach_persona
  has_many :cohorts, through: :cohort_persona_assignments
  has_many :draft_content_pack_links,
    -> { order(:position) },
    class_name: "CoachPersonaDraftContentPack",
    dependent: :destroy,
    inverse_of: :coach_persona
  has_many :draft_content_pack_versions, through: :draft_content_pack_links, source: :coach_content_pack_version

  normalizes :name, with: ->(name) { name.to_s.strip }

  validates :name, presence: true, length: { maximum: 120 }, uniqueness: { case_sensitive: false, scope: :created_by_user_id }
  validates :description, length: { maximum: 2_000 }, allow_blank: true
  validates :preview_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validate :creator_is_staff, on: :create
  validate :draft_config_matches_schema
  validate :preview_fields_are_complete
  validate :current_version_belongs_to_persona
  validate :archived_persona_is_read_only, on: :update

  before_validation :normalize_draft_config
  before_validation :synchronize_name_from_draft
  before_update :track_draft_revision_and_preview

  def published?
    current_published_version_id.present?
  end

  def archived?
    archived_at.present?
  end

  def live_cohort_assignments?
    cohort_persona_assignments.joins(:cohort).where(cohorts: { status: LIVE_COHORT_STATUSES }).exists?
  end

  def archive!
    update!(archived_at: Time.current)
  end

  def restore!
    update!(archived_at: nil)
  end

  def apply_rollback_version!(version)
    raise ArgumentError, "rollback version must belong to this persona" unless version.coach_persona_id == id

    @force_draft_revision_and_preview_reset = true
    update!(draft_config: version.config.deep_dup, current_published_version: version)
  ensure
    @force_draft_revision_and_preview_reset = false
  end

  def replace_draft_content_pack_versions!(versions, actor:, expected_draft_revision: draft_revision)
    raise ContentPackSelectionError, "Not authorized to edit this persona" unless actor&.admin? || created_by_user_id == actor&.id
    raise ContentPackSelectionError, "Archived personas are read-only" if archived?

    normalized = Array(versions).uniq(&:id)
    raise ContentPackSelectionError, "A persona can use at most 12 content packs" if normalized.length > 12
    normalized.each do |version|
      raise ContentPackSelectionError, "Content pack version is not a valid sealed publication" unless version.manifest_valid?

      pack = version.coach_content_pack
      next if pack.scope == "platform" || pack.created_by_user_id == created_by_user_id

      raise ContentPackSelectionError, "Content packs from another coach cannot be attached"
    end

    with_lock do
      unless Integer(expected_draft_revision, exception: false) == draft_revision
        raise DraftConflict, "The persona draft changed; reload it before changing content packs"
      end
      return if draft_content_pack_links.order(:position).pluck(:coach_content_pack_version_id) == normalized.map(&:id)

      draft_content_pack_links.delete_all
      normalized.each_with_index { |version, position| draft_content_pack_links.create!(coach_content_pack_version: version, position: position) }
      update_columns(
        draft_revision: draft_revision + 1,
        preview_digest: nil,
        previewed_at: nil,
        previewed_draft_revision: nil,
        updated_at: Time.current,
        lock_version: lock_version + 1
      )
    end
  end

  def draft_content_pack_versions_ordered
    draft_content_pack_links.includes(coach_content_pack_version: { entries: :coach_content_item_version }).order(:position).map(&:coach_content_pack_version)
  end

  def draft_content_manifest_digest
    CoachPersonaVersion.content_manifest_digest_for(draft_content_pack_versions_ordered)
  end

  def draft_content_manifest_entries
    draft_content_pack_versions_ordered.each_with_index.map do |version, position|
      CoachPersonaVersion.content_manifest_entry(version, position: position)
    end
  end

  private

  def normalize_draft_config
    self.draft_config = Mia::PersonaSchema.normalize(draft_config) if draft_config.is_a?(Hash)
  end

  def synchronize_name_from_draft
    configured_name = draft_config.to_h.dig("identity", "assistant_name").to_s.squish
    self.name = configured_name if configured_name.present?
  end

  def creator_is_staff
    errors.add(:created_by_user, "must be a coach or admin") unless created_by_user&.staff?
  end

  def draft_config_matches_schema
    Mia::PersonaSchema.errors(draft_config).each { |message| errors.add(:draft_config, message) }
  end

  def preview_fields_are_complete
    fields = [ preview_digest, previewed_at, previewed_draft_revision ]
    return if fields.all?(&:blank?) || fields.all?(&:present?)

    errors.add(:preview_digest, "and preview metadata must all be present or all be blank")
  end

  def current_version_belongs_to_persona
    return if current_published_version.nil?
    return if current_published_version.coach_persona == self

    errors.add(:current_published_version, "must belong to this persona")
  end

  def archived_persona_is_read_only
    return if archived_at_was.blank?

    protected_changes = changes_to_save.keys - %w[archived_at updated_at lock_version]
    errors.add(:base, "archived personas are read-only until restored") if protected_changes.any?
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
