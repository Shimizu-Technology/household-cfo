# frozen_string_literal: true

class CoachContentPack < ApplicationRecord
  SCOPES = CoachContentItem::SCOPES
  KINDS = %w[voice_culture coaching_method finance_reference].freeze

  belongs_to :created_by_user, class_name: "User", inverse_of: :created_coach_content_packs
  belongs_to :current_published_version, class_name: "CoachContentPackVersion", optional: true
  has_many :draft_entries, -> { order(:position) }, class_name: "CoachContentPackDraftEntry", dependent: :destroy, inverse_of: :coach_content_pack
  has_many :draft_item_versions, through: :draft_entries, source: :coach_content_item_version
  has_many :versions, -> { order(:version_number) }, class_name: "CoachContentPackVersion", dependent: :restrict_with_exception, inverse_of: :coach_content_pack

  normalizes :name, with: ->(value) { value.to_s.squish }
  validates :name, presence: true, length: { maximum: 160 }, uniqueness: { case_sensitive: false, scope: [ :created_by_user_id, :scope ] }
  validates :description, length: { maximum: 2_000 }, allow_blank: true
  validates :scope, inclusion: { in: SCOPES }
  validates :pack_kind, inclusion: { in: KINDS }
  validates :draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validate :creator_can_manage_scope, on: :create
  validate :current_version_belongs_to_pack
  validate :archived_pack_is_read_only, on: :update
  before_update :advance_draft_revision

  def archived?
    archived_at.present?
  end

  def replace_draft_item_versions!(versions, actor:)
    raise ArgumentError, "Not authorized for this pack" unless manageable_by?(actor)
    raise ArgumentError, "Archived packs are read-only" if archived?

    normalized = Array(versions).uniq(&:id)
    validate_versions!(normalized, actor: actor)
    with_lock do
      return if draft_entries.order(:position).pluck(:coach_content_item_version_id) == normalized.map(&:id)

      draft_entries.delete_all
      normalized.each_with_index { |version, position| draft_entries.create!(coach_content_item_version: version, position: position) }
      increment!(:draft_revision)
    end
  end

  def publish!(actor:)
    raise ArgumentError, "Not authorized for this pack" unless manageable_by?(actor)
    raise ArgumentError, "Archived packs cannot be published" if archived?
    raise ArgumentError, "Add at least one approved item before publishing" if draft_entries.empty?

    with_lock do
      digest = CoachContentPackVersion.digest_for(self, draft_entries.includes(:coach_content_item_version))
      return current_published_version if current_published_version&.content_digest == digest

      version = versions.create!(
        version_number: versions.maximum(:version_number).to_i + 1,
        name: name,
        description: description,
        scope: scope,
        pack_kind: pack_kind,
        content_digest: digest,
        published_by_user: actor
      )
      draft_entries.includes(:coach_content_item_version).each do |entry|
        version.entries.create!(coach_content_item_version: entry.coach_content_item_version, position: entry.position)
      end
      update_columns(current_published_version_id: version.id, updated_at: Time.current, lock_version: lock_version + 1)
      version
    end
  end

  def manageable_by?(actor)
    actor&.admin? || (scope == "coach" && created_by_user_id == actor&.id)
  end

  private

  def validate_versions!(versions, actor:)
    raise ArgumentError, "Add at least one approved item" if versions.empty?
    raise ArgumentError, "A pack can contain at most 30 items" if versions.length > 30
    raise ArgumentError, "Choose only one approved version of each item" if versions.map(&:coach_content_item_id).uniq.length != versions.length

    versions.each do |version|
      item = version.coach_content_item
      if scope == "platform" && item.scope != "platform"
        raise ArgumentError, "Platform packs can contain only platform content"
      end
      next if item.scope == "platform" || item.created_by_user_id == created_by_user_id

      raise ArgumentError, "Content from another coach cannot be added"
    end
  end

  def creator_can_manage_scope
    errors.add(:created_by_user, "must be a coach or admin") unless created_by_user&.staff?
    errors.add(:scope, "platform packs can be created only by an administrator") if scope == "platform" && !created_by_user&.admin?
  end

  def current_version_belongs_to_pack
    return if current_published_version.nil? || current_published_version.coach_content_pack == self

    errors.add(:current_published_version, "must belong to this pack")
  end

  def advance_draft_revision
    return unless will_save_change_to_name? || will_save_change_to_description? || will_save_change_to_pack_kind?

    self.draft_revision = draft_revision_was + 1
  end

  def archived_pack_is_read_only
    return if archived_at_was.blank?

    protected_changes = changes_to_save.keys - %w[archived_at updated_at lock_version]
    errors.add(:base, "archived content packs are read-only") if protected_changes.any?
  end
end
