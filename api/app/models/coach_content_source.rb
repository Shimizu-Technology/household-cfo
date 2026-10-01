# frozen_string_literal: true

class CoachContentSource < ApplicationRecord
  MAX_ACTIVE_SOURCES_PER_OWNER = 100
  MAX_ACTIVE_BYTES_PER_OWNER = 512 * 1024 * 1024
  MAX_IN_FLIGHT_UPLOADS_PER_OWNER = 5
  MAX_NEW_UPLOADS_PER_WINDOW = 10
  UPLOAD_WINDOW = 15.minutes

  SCOPES = CoachContentItem::SCOPES
  STATUSES = %w[uploading verifying upload_cleanup queued processing needs_review failed deletion_pending deletion_failed source_deleted].freeze

  belongs_to :created_by_user, class_name: "User"
  belongs_to :source_deleted_by_user, class_name: "User", optional: true
  belongs_to :current_attempt, class_name: "CoachContentSourceAttempt", optional: true
  has_many :attempts, class_name: "CoachContentSourceAttempt", dependent: :restrict_with_exception
  has_many :candidates, class_name: "CoachContentSourceCandidate", dependent: :restrict_with_exception
  has_many :draft_provenances, class_name: "CoachContentItemDraftProvenance", dependent: :restrict_with_exception
  has_many :version_provenances, class_name: "CoachContentItemVersionProvenance", dependent: :restrict_with_exception

  validates :scope, inclusion: { in: SCOPES }
  validates :status, inclusion: { in: STATUSES }
  validates :filename, presence: true, length: { maximum: 255 }
  validates :content_type, presence: true, length: { maximum: 255 }
  validates :byte_size, numericality: { only_integer: true, greater_than: 0 }
  validates :checksum_sha256, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :upload_request_id, presence: true, length: { maximum: 100 }, uniqueness: { scope: :created_by_user_id }
  validates :generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :creator_can_manage_scope, on: :create
  validate :current_attempt_belongs_to_source
  validate :upload_identity_is_immutable, on: :update

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def source_available?
    s3_key.present? && source_deleted_at.blank? && deletion_requested_at.blank? &&
      !status.in?(%w[uploading verifying upload_cleanup deletion_pending deletion_failed source_deleted])
  end

  def active_for_processing?
    source_available? && status.in?(%w[queued failed])
  end

  def deleted?
    source_deleted_at.present? && status == "source_deleted"
  end

  private

  def creator_can_manage_scope
    errors.add(:created_by_user, "must be a coach or admin") unless created_by_user&.staff?
    errors.add(:scope, "platform sources can be created only by an administrator") if scope == "platform" && !created_by_user&.admin?
  end

  def current_attempt_belongs_to_source
    return if current_attempt.nil? || current_attempt.coach_content_source_id == id

    errors.add(:current_attempt, "must belong to this source")
  end

  def upload_identity_is_immutable
    protected_fields = %w[scope created_by_user_id filename content_type byte_size checksum_sha256 upload_request_id]
    errors.add(:base, "source upload identity is immutable") if changes_to_save.keys.intersect?(protected_fields)
    if will_save_change_to_s3_key? && !(s3_key.nil? && status == "source_deleted")
      errors.add(:s3_key, "can only be cleared after confirmed source deletion")
    end
  end
end
