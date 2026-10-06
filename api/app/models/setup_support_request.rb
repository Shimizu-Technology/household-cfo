class SetupSupportRequest < ApplicationRecord
  REASONS = { "practice_numbers" => "I used practice numbers", "wrong_setup" => "My starting setup is wrong",
    "upload_problem" => "I need help with an upload", "other" => "I need help starting again" }.freeze
  STATUSES = %w[requested in_review ready applied canceled declined].freeze
  ACTIVE = %w[requested in_review ready].freeze
  belongs_to :household
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :cohort, optional: true
  belongs_to :prepared_by_user, class_name: "User", optional: true
  belongs_to :financial_restart_review, optional: true
  has_many :setup_help_request_keys, dependent: :restrict_with_exception
  validates :reason, inclusion: { in: REASONS.keys }
  validates :status, inclusion: { in: STATUSES }
end
