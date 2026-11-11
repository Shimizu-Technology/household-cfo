class ChatSession < ApplicationRecord
  include CurrentFinancialPicture
  belongs_to :household
  belongs_to :user
  belongs_to :cohort, optional: true

  has_many :chat_messages, dependent: :destroy
  has_many :mia_message_requests, dependent: :destroy

  before_update :guard_financial_request_generation
  before_update :preserve_active_care_topic

  validates :user_id, uniqueness: { scope: [ :household_id, :cohort_id ] }
  validate :scope_is_immutable, on: :update

  def with_financial_picture_lock(&block)
    household.with_lock { with_lock(&block) }
  end

  def title_or_default
    title.presence || "Ask Mia"
  end

  # Only the care state machine may release care after recovery or expiry.
  # Other writers (including stale document/setup turns) retain the episode.
  def release_care_topic!
    @releasing_care_topic = true
    update!(active_topic: {})
  ensure
    @releasing_care_topic = false
  end

  private

  def preserve_active_care_topic
    return if @releasing_care_topic || !will_save_change_to_active_topic? || active_topic.to_h["type"] == "care"

    persisted = self.class.lock.find(id)
    topic = persisted.active_topic.to_h
    return unless topic["type"] == "care"

    expiry = Time.zone.parse(topic["expires_at"].to_s) rescue nil
    expiry ||= (persisted.chat_messages.maximum(:created_at) || persisted.updated_at) + HouseholdFinance::ParticipantCareState::TTL
    self.active_topic = topic if expiry > Time.current
  end

  def guard_financial_request_generation
    HouseholdFinance::FinancialGenerationGuard.request!(household.reload)
  end

  def scope_is_immutable
    if will_save_change_to_household_id? || will_save_change_to_user_id? || will_save_change_to_cohort_id?
      errors.add(:base, "conversation actor and program are immutable")
    end
  end
end
