class ChatSession < ApplicationRecord
  include CurrentFinancialPicture
  belongs_to :household
  belongs_to :user
  belongs_to :cohort, optional: true

  has_many :chat_messages, dependent: :destroy
  has_many :mia_message_requests, dependent: :destroy

  before_update :guard_financial_request_generation

  validates :user_id, uniqueness: { scope: [ :household_id, :cohort_id ] }
  validate :scope_is_immutable, on: :update

  def with_financial_picture_lock(&block)
    household.with_lock { with_lock(&block) }
  end

  def title_or_default
    title.presence || "Ask Mia"
  end

  private

  def guard_financial_request_generation
    HouseholdFinance::FinancialGenerationGuard.request!(household.reload)
  end

  def scope_is_immutable
    if will_save_change_to_household_id? || will_save_change_to_user_id? || will_save_change_to_cohort_id?
      errors.add(:base, "conversation actor and program are immutable")
    end
  end
end
