# frozen_string_literal: true

class CoachContentSourceUrlIntake < ApplicationRecord
  STATUSES = %w[queued fetching staged registering registered failed cleanup_pending cleanup_failed deleted].freeze
  ACTIVE_RESERVATION_STATUSES = %w[queued fetching staged registering cleanup_pending cleanup_failed].freeze

  belongs_to :created_by_user, class_name: "User"
  belongs_to :coach_workspace, optional: true
  belongs_to :coach_content_source, optional: true

  validates :scope, inclusion: { in: CoachContentSource::SCOPES }
  validates :status, inclusion: { in: STATUSES }
  validates :request_id, presence: true, length: { maximum: 100 }
  validates :encrypted_url_ciphertext, :encrypted_url_iv, :encrypted_url_auth_tag, presence: true, unless: :url_redacted?
  validates :encryption_key_version, :hmac_key_version, numericality: { only_integer: true, greater_than: 0 }
  validates :url_identity_hmac, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :reserved_bytes, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 12 * 1024 * 1024 }
  validates :redirect_count, numericality: { only_integer: true, in: 0..3 }
  validates :fetched_checksum_sha256, allow_nil: true, format: { with: /\A[0-9a-f]{64}\z/ }
  validate :workspace_matches_scope
  validate :source_matches_boundary
  validate :source_state_is_coherent

  scope :reserving_quota, -> { where(status: ACTIVE_RESERVATION_STATUSES) }

  def encrypted_url_payload
    {
      ciphertext: encrypted_url_ciphertext,
      iv: encrypted_url_iv,
      auth_tag: encrypted_url_auth_tag,
      key_version: encryption_key_version
    }
  end

  def registered?
    status == "registered" && coach_content_source_id.present?
  end

  def url_redacted?
    status == "deleted" || redaction_requested_at.present?
  end

  def redaction_allowed?
    coach_content_source_id.nil? && status.in?(%w[failed cleanup_failed])
  end

  def redaction_pending?
    redaction_requested_at.present? && status != "deleted"
  end

  def request_redaction!
    cleanup_required = false
    with_lock do
      return :already_redacted if status == "deleted" && coach_content_source_id.nil?
      raise ContentSources::Error, "url_intake_conflict" unless redaction_allowed?

      now = Time.current
      cleanup_required = staging_s3_key.present? || final_s3_key.present?
      update!(
        status: cleanup_required ? "cleanup_pending" : "deleted",
        redaction_requested_at: now,
        encrypted_url_ciphertext: nil,
        encrypted_url_iv: nil,
        encrypted_url_auth_tag: nil,
        completed_at: now
      )
    end
    cleanup_required ? :cleanup_required : :redacted
  end

  private

  def workspace_matches_scope
    valid = (scope == "coach" && coach_workspace.present?) || (scope == "platform" && coach_workspace.nil?)
    errors.add(:coach_workspace, "must match the content scope") unless valid
  end

  def source_matches_boundary
    return unless coach_content_source

    unless coach_content_source.scope == scope && coach_content_source.coach_workspace_id == coach_workspace_id &&
        coach_content_source.created_by_user_id == created_by_user_id && coach_content_source.ingestion_method == "url_snapshot"
      errors.add(:coach_content_source, "must belong to the same URL intake boundary")
    end
  end

  def source_state_is_coherent
    valid = if status == "registered"
      coach_content_source.present?
    elsif status == "deleted"
      true
    else
      coach_content_source.nil?
    end
    return if valid

    errors.add(:coach_content_source, "must match the URL intake lifecycle state")
  end
end
