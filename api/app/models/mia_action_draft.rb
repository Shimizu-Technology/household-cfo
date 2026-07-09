class MiaActionDraft < ApplicationRecord
  STATUSES = %w[pending applied canceled].freeze
  DRAFT_TYPES = %w[budget_edit].freeze

  belongs_to :household
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :source_chat_message, class_name: "ChatMessage", optional: true
  belongs_to :assistant_chat_message, class_name: "ChatMessage", optional: true
  belongs_to :applied_by_user, class_name: "User", optional: true
  belongs_to :canceled_by_user, class_name: "User", optional: true

  has_many :mia_action_items, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :mia_action_draft

  validates :status, inclusion: { in: STATUSES }
  validates :draft_type, inclusion: { in: DRAFT_TYPES }
  validates :year, numericality: { only_integer: true, greater_than_or_equal_to: 2000, less_than_or_equal_to: 2100 }
  validates :title, presence: true, length: { maximum: 160 }
  validates :summary, presence: true, length: { maximum: 1_000 }
  validates :source_prompt, length: { maximum: ChatMessage::MAX_CONTENT_LENGTH }, allow_blank: true

  scope :pending, -> { where(status: "pending") }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def pending?
    status == "pending"
  end
end
