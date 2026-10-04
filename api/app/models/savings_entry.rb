class SavingsEntry < ApplicationRecord
  belongs_to :savings_enrollment
  belongs_to :current_approved_version, class_name: "SavingsEntryVersion", optional: true
  has_many :savings_entry_versions, dependent: :restrict_with_exception
  has_many :savings_entry_drafts, dependent: :restrict_with_exception
end
