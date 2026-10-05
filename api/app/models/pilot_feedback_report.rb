class PilotFeedbackReport < ApplicationRecord
  WORKFLOWS = %w[
    sign_in
    home
    setup
    ask_mia
    voice
    budget
    transaction_review
    receipt_upload
    statement_upload
    document_upload
    private_document
    admin
    other
  ].freeze
  STATUSES = %w[submitted reviewed resolved].freeze
  SUPPORT_SHARING_POLICY_VERSION = "technical_support_v1".freeze
  MAX_DETAIL_LENGTH = 2_000

  belongs_to :household
  belongs_to :user

  validates :workflow, inclusion: { in: WORKFLOWS }
  validates :status, inclusion: { in: STATUSES }
  validates :attempted, :expected, :actual, presence: true, length: { maximum: MAX_DETAIL_LENGTH }
  validates :screenshot_s3_key, length: { maximum: 1_024 }, allow_blank: true
  validates :screenshot_filename, :screenshot_content_type, length: { maximum: 255 }, allow_blank: true
  validates :screenshot_byte_size, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  validates :support_sharing_policy_version, inclusion: { in: [ SUPPORT_SHARING_POLICY_VERSION ] }, allow_nil: true
  validate :support_sharing_is_consistent

  scope :shared_with_support, -> { where(support_sharing_policy_version: SUPPORT_SHARING_POLICY_VERSION, support_sharing_revoked_at: nil).where.not(support_sharing_approved_at: nil) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def support_sharing_granted?
    support_sharing_approved_at.present? && support_sharing_policy_version == SUPPORT_SHARING_POLICY_VERSION && support_sharing_revoked_at.nil?
  end

  def support_access_available?
    support_sharing_revoked_at.nil? && (support_sharing_granted? || !ChallengePrivacy::PrivateFinanceAccess.pilot_household?(household))
  end

  def screenshot?
    screenshot_s3_key.present?
  end
  private

  def support_sharing_is_consistent
    if support_sharing_approved_at.present? != support_sharing_policy_version.present?
      errors.add(:support_sharing_policy_version, "requires the matching approval time")
    end
    if support_sharing_approved_at && support_sharing_revoked_at && support_sharing_revoked_at < support_sharing_approved_at
      errors.add(:support_sharing_revoked_at, "cannot precede approval")
    end
  end
end
