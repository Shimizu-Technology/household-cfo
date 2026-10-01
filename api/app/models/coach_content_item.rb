# frozen_string_literal: true

class CoachContentItem < ApplicationRecord
  SCOPES = %w[coach platform].freeze
  KINDS = %w[guidance script example phrase culture finance_reference].freeze

  belongs_to :created_by_user, class_name: "User", inverse_of: :created_coach_content_items
  belongs_to :current_approved_version, class_name: "CoachContentItemVersion", optional: true
  has_many :versions, -> { order(:version_number) }, class_name: "CoachContentItemVersion", dependent: :restrict_with_exception, inverse_of: :coach_content_item
  has_many :draft_pack_entries, class_name: "CoachContentPackDraftEntry", dependent: :restrict_with_exception

  normalizes :title, with: ->(value) { value.to_s.squish }
  normalizes :draft_content, with: ->(value) { value.to_s.strip }

  validates :title, presence: true, length: { maximum: 160 }, uniqueness: { case_sensitive: false, scope: [ :created_by_user_id, :scope ] }
  validates :scope, inclusion: { in: SCOPES }
  validates :kind, inclusion: { in: KINDS }
  validates :draft_content, presence: true, length: { maximum: 10_000 }
  validates :draft_revision, numericality: { only_integer: true, greater_than: 0 }
  validate :creator_can_manage_scope, on: :create
  validate :current_version_belongs_to_item
  validate :archived_item_is_read_only, on: :update
  validate :draft_content_has_bounded_bytes

  before_update :advance_draft_revision

  def archived?
    archived_at.present?
  end

  def approve!(actor:)
    raise ArgumentError, "Only staff can approve content" unless actor&.staff?
    raise ArgumentError, "Only administrators can approve platform content" if scope == "platform" && !actor.admin?
    raise ArgumentError, "Not authorized for this content item" unless actor.admin? || created_by_user_id == actor.id
    raise ArgumentError, "Archived content cannot be approved" if archived?

    with_lock do
      digest = CoachContentItemVersion.digest_for(title: title, kind: kind, content: draft_content)
      if current_approved_version&.content_digest == digest
        return current_approved_version
      end

      version = versions.create!(
        version_number: versions.maximum(:version_number).to_i + 1,
        title: title,
        kind: kind,
        content: draft_content,
        content_digest: digest,
        approved_by_user: actor
      )
      update_columns(current_approved_version_id: version.id, updated_at: Time.current, lock_version: lock_version + 1)
      version
    end
  end

  private

  def creator_can_manage_scope
    errors.add(:created_by_user, "must be a coach or admin") unless created_by_user&.staff?
    errors.add(:scope, "platform content can be created only by an administrator") if scope == "platform" && !created_by_user&.admin?
  end

  def current_version_belongs_to_item
    return if current_approved_version.nil? || current_approved_version.coach_content_item == self

    errors.add(:current_approved_version, "must belong to this content item")
  end

  def advance_draft_revision
    return unless will_save_change_to_title? || will_save_change_to_kind? || will_save_change_to_draft_content?

    self.draft_revision = draft_revision_was + 1
  end

  def archived_item_is_read_only
    return if archived_at_was.blank?

    protected_changes = changes_to_save.keys - %w[archived_at updated_at lock_version]
    errors.add(:base, "archived content is read-only") if protected_changes.any?
  end

  def draft_content_has_bounded_bytes
    errors.add(:draft_content, "is too large (maximum is 12,000 bytes)") if draft_content.to_s.bytesize > 12_000
  end
end
