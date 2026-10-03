# frozen_string_literal: true

class CoachWorkspaceDomain < ApplicationRecord
  HOSTNAME_FORMAT = /\A(?=.{4,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}\z/
  KINDS = %w[managed_subdomain custom].freeze
  STATUSES = %w[pending verified active disabled].freeze

  belongs_to :coach_workspace, inverse_of: :coach_workspace_domains
  belongs_to :created_by_user, class_name: "User", inverse_of: :created_workspace_domains
  belongs_to :updated_by_user, class_name: "User", inverse_of: :updated_workspace_domains
  has_many :lifecycle_events, class_name: "CoachWorkspaceDomainEvent", dependent: :restrict_with_exception, inverse_of: :coach_workspace_domain

  normalizes :hostname, with: ->(value) { value.to_s.strip.downcase }

  validates :hostname, presence: true, format: { with: HOSTNAME_FORMAT }, uniqueness: { case_sensitive: false }
  validates :kind, inclusion: { in: KINDS }
  validates :status, inclusion: { in: STATUSES }
  validates :verification_token_digest, format: { with: /\A[0-9a-f]{64}\z/ }, allow_nil: true
  validates :lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :creator_can_edit_workspace, on: :create
  validate :updater_can_edit_workspace
  validate :verified_identity_is_immutable, on: :update
  validate :lifecycle_fields_are_consistent
  after_commit :invalidate_active_domain_registry

  scope :active, -> { where(status: "active").where.not(verified_at: nil).where.not(activated_at: nil) }

  private

  def creator_can_edit_workspace
    errors.add(:created_by_user, "cannot edit this coach workspace") unless coach_workspace&.allows?(created_by_user, :edit)
  end

  def updater_can_edit_workspace
    errors.add(:updated_by_user, "cannot edit this coach workspace") unless coach_workspace&.allows?(updated_by_user, :edit)
  end

  def verified_identity_is_immutable
    return unless will_save_change_to_hostname? || will_save_change_to_kind?
    return if verification_requested_at_was.nil? && verified_at_was.nil? && activated_at_was.nil? && status_was == "pending"

    errors.add(:base, "hostname and kind cannot change after domain verification begins")
  end

  def lifecycle_fields_are_consistent
    if status.in?(%w[verified active]) && verified_at.nil?
      errors.add(:verified_at, "is required for a verified domain")
    end
    if status == "active" && activated_at.nil?
      errors.add(:activated_at, "is required for an active domain")
    end
    if is_primary? && status != "active"
      errors.add(:is_primary, "is only allowed for an active domain")
    end
    if status == "disabled" && disabled_at.nil?
      errors.add(:disabled_at, "is required for a disabled domain")
    end
    if status != "disabled" && disabled_at.present?
      errors.add(:disabled_at, "must be blank unless the domain is disabled")
    end
  end

  def invalidate_active_domain_registry
    Branding::ActiveDomainRegistry.invalidate!
  end
end
