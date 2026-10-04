class SavingsCheckpointVersion < ApplicationRecord
  include SavingsDailyRecord
  include SavingsImmutable
  belongs_to :savings_checkpoint
  belongs_to :approved_by_user, class_name: "User"
  belongs_to :previous_version, class_name: "SavingsCheckpointVersion", optional: true
  validates :approved_at, presence: true
  validates :version_number, numericality: { only_integer: true, greater_than: 0 }
  validates :reason, length: { maximum: 500 }
  validate :approved_snapshot

  private

  def approved_snapshot
    return unless savings_enrollment && savings_checkpoint
    SavingsChallenge::CheckpointSnapshot.validate!(enrollment: savings_enrollment, checkpoint: savings_checkpoint, snapshot: snapshot, previous: previous_version)
  rescue ArgumentError, ActiveRecord::RecordNotFound => error
    errors.add(:snapshot, error.message)
  end
end
