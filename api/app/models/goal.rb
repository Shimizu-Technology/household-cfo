class Goal < ApplicationRecord
  include CurrentFinancialPicture
  GOAL_TYPES = %w[runway debt_payoff business_income purchase transition savings education business travel home retirement other].freeze
  TRACKED_GOAL_TYPES = (GOAL_TYPES - %w[runway transition]).freeze
  RECORD_KINDS = %w[tracked policy].freeze
  SOURCE_TYPES = %w[manual_ui mia document_import setup].freeze

  belongs_to :household

  before_validation :classify_legacy_policy_record

  scope :tracked, -> { where(record_kind: "tracked") }
  scope :policy, -> { where(record_kind: "policy") }
  scope :active, -> { where(active: true) }
  scope :archived, -> { where(active: false) }

  validates :label, presence: true, length: { maximum: 120 }
  validates :goal_type, inclusion: { in: GOAL_TYPES }
  validates :record_kind, inclusion: { in: RECORD_KINDS }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :goal_type, uniqueness: { scope: [ :household_id, :financial_generation ] }, if: :single_setup_goal_type?
  validates :target_amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :current_amount_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :priority, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :target_months, absence: true, if: :tracked?
  validate :tracked_type_is_supported
  validate :active_name_is_unique
  validate :archive_state_is_consistent
  validate :amount_states_are_consistent
  validate :source_metadata_is_object

  def tracked?
    record_kind == "tracked"
  end

  private

  def classify_legacy_policy_record
    self.record_kind = "policy" if goal_type.in?(%w[runway transition])
    self.target_amount_known = true if new_record? && target_amount_cents.to_i.nonzero? && !target_amount_known?
    self.current_amount_known = true if new_record? && current_amount_cents.to_i.nonzero? && !current_amount_known?
  end

  def single_setup_goal_type?
    record_kind == "policy" && goal_type.in?([ "runway", "transition" ])
  end

  def tracked_type_is_supported
    return unless tracked?
    errors.add(:goal_type, "is reserved for household policy") unless goal_type.in?(TRACKED_GOAL_TYPES)
  end

  def active_name_is_unique
    return unless tracked? && active? && household_id && label.present? && goal_type.present?
    scope = self.class.tracked.active.where(financial_generation: financial_generation, household_id: household_id, goal_type: goal_type)
      .where("LOWER(label) = ?", label.to_s.downcase)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:label, "has already been taken") if scope.exists?
  end

  def archive_state_is_consistent
    errors.add(:archived_at, "must be blank for an active goal") if active? && archived_at.present?
    errors.add(:archived_at, "is required for an archived goal") unless active? || archived_at.present?
  end

  def amount_states_are_consistent
    errors.add(:target_amount_cents, "must be zero while the target is unknown") unless target_amount_known? || target_amount_cents.to_i.zero?
    errors.add(:current_amount_cents, "must be zero while progress is unknown") unless current_amount_known? || current_amount_cents.to_i.zero?
  end

  def source_metadata_is_object
    errors.add(:source_metadata, "must be an object") unless source_metadata.is_a?(Hash)
  end
end
