class CoachLaunchReceipt < ApplicationRecord
  belongs_to :coach_workspace
  belongs_to :user
  belongs_to :coach_persona
end
