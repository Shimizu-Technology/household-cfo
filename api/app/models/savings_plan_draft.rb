class SavingsPlanDraft < ApplicationRecord
  belongs_to :savings_enrollment
  belongs_to :created_by_user, class_name: "User"
  belongs_to :base_plan_version, class_name: "SavingsPlanVersion", optional: true
  belongs_to :approved_plan_version, class_name: "SavingsPlanVersion", optional: true
  belongs_to :financial_baseline_version, optional: true
  validates :target_cents, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :reason, length: { maximum: 500 }
  validates :status, inclusion: { in: %w[pending approved] }
  validate :participant_boundary

  # What the participant should see: every approved draft, plus ONE pending
  # draft, the latest one built on the plan that is current right now. Older
  # duplicates (a second "Review target plan" click) and drafts built on a plan
  # that has since been replaced are superseded: kept for the record, but not
  # listed, not counted and not approvable.
  def self.current_pending_id(enrollment)
    where(savings_enrollment_id: enrollment.id, status: "pending", base_plan_version_id: enrollment.current_accepted_plan_version_id).maximum(:id)
  end

  def self.visible_for(enrollment)
    where(savings_enrollment_id: enrollment.id).where("status = 'approved' OR id = ?", current_pending_id(enrollment) || 0)
  end

  def self.superseded?(draft, enrollment)
    draft.status == "pending" && draft.id != current_pending_id(enrollment)
  end

  private

  def participant_boundary
    errors.add(:created_by_user, "must be the participant") unless created_by_user_id == savings_enrollment&.user_id
    errors.add(:target_cents, "must be integer cents or nil") unless target_cents_before_type_cast.nil? || target_cents_before_type_cast.instance_of?(Integer)
    errors.add(:base_plan_version, "must belong to this enrollment") if base_plan_version && base_plan_version.savings_enrollment_id != savings_enrollment_id
  end
end
