class MerchantCategoryRule < ApplicationRecord
  SOURCES = %w[user_confirmed system_inferred coach_confirmed].freeze

  belongs_to :household
  belongs_to :budget_category

  validates :merchant_pattern, presence: true, length: { maximum: 120 }
  validates :source, inclusion: { in: SOURCES }
  validates :confidence, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :times_confirmed, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :category_belongs_to_household

  scope :active, -> { where(active: true) }
  scope :best_first, -> { order(confidence: :desc, times_confirmed: :desc, last_confirmed_at: :desc) }

  def self.normalized_pattern(value)
    value.to_s.unicode_normalize(:nfkc).downcase.gsub(/[^a-z0-9&'\s.-]/, " ").squish.truncate(120, omission: "…")
  end

  private

  def category_belongs_to_household
    return unless budget_category && household_id

    errors.add(:budget_category, "must belong to household") unless budget_category.household_id == household_id
  end
end
