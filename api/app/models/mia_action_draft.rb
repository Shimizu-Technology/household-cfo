class MiaActionDraft < ApplicationRecord
  include CurrentFinancialPicture
  STATUSES = %w[pending partially_applied applied canceled].freeze
  DRAFT_TYPES = %w[budget_edit household_setup income_schedule debt_plan asset_plan goal_plan action_plan].freeze

  belongs_to :household
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :source_chat_message, class_name: "ChatMessage", optional: true
  belongs_to :assistant_chat_message, class_name: "ChatMessage", optional: true
  belongs_to :applied_by_user, class_name: "User", optional: true
  belongs_to :canceled_by_user, class_name: "User", optional: true

  has_many :mia_action_items, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :mia_action_draft
  has_many :mia_action_draft_applications, dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :draft_type, inclusion: { in: DRAFT_TYPES }
  validates :year, numericality: { only_integer: true, greater_than_or_equal_to: 2000, less_than_or_equal_to: 2100 }
  validates :title, presence: true, length: { maximum: 160 }
  validates :summary, presence: true, length: { maximum: 1_000 }
  validates :source_prompt, length: { maximum: ChatMessage::MAX_CONTENT_LENGTH }, allow_blank: true
  validate :chat_messages_belong_to_household

  scope :pending, -> { where(status: "pending") }
  scope :reviewable, -> { where(status: %w[pending partially_applied]) }
  scope :for_budget_year, ->(year) do
    timeless_types = %w[household_setup debt_plan]
    year_dependent_operations = HouseholdFinance::MiaActionPlanBuilder::YEAR_DEPENDENT_OPERATION_KEYS
    where(
      <<~SQL.squish,
        draft_type IN (:timeless_types)
        OR year = :year
        OR (
          draft_type = 'action_plan'
          AND NOT EXISTS (
            SELECT 1
            FROM mia_action_items
            WHERE mia_action_items.mia_action_draft_id = mia_action_drafts.id
              AND mia_action_items.operation_key IN (:year_dependent_operations)
          )
        )
      SQL
      timeless_types: timeless_types,
      year: year.to_i,
      year_dependent_operations: year_dependent_operations
    )
  end
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def pending?
    status == "pending"
  end

  def reviewable?
    status.in?(%w[pending partially_applied])
  end

  private

  def chat_messages_belong_to_household
    { source_chat_message: source_chat_message, assistant_chat_message: assistant_chat_message }.each do |name, message|
      next if message.blank? || message.chat_session&.household_id == household_id

      errors.add(name, "must belong to the Mia action household")
    end
  end
end
