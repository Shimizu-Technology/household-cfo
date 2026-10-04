class SavingsCheckpointDraft < ApplicationRecord
  include SavingsDailyRecord
  belongs_to :savings_checkpoint
  belongs_to :created_by_user, class_name: "User"
  belongs_to :base_version, class_name: "SavingsCheckpointVersion", optional: true
  belongs_to :approved_version, class_name: "SavingsCheckpointVersion", optional: true
  validates :status, inclusion: { in: %w[pending approved] }
  validates :reason, length: { maximum: 500 }
end
