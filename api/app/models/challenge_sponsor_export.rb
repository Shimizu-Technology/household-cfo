class ChallengeSponsorExport < ApplicationRecord
  include SavingsImmutable
  belongs_to :cohort
  belongs_to :approved_by_user, class_name: "User"
  validates :checkpoint_day, inclusion: { in: [ 30, 60, 90 ] }
  validates :digest, :policy_version, :resolved_cutoff_on, presence: true
end
