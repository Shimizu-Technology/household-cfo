class ChatSession < ApplicationRecord
  belongs_to :household
  belongs_to :user
  belongs_to :cohort, optional: true

  has_many :chat_messages, dependent: :destroy
  has_many :mia_message_requests, dependent: :destroy

  validates :user_id, uniqueness: { scope: [ :household_id, :cohort_id ] }
  validate :scope_is_immutable, on: :update

  def title_or_default
    title.presence || "Ask Mia"
  end

  private

  def scope_is_immutable
    if will_save_change_to_household_id? || will_save_change_to_user_id? || will_save_change_to_cohort_id?
      errors.add(:base, "conversation actor and program are immutable")
    end
  end
end
