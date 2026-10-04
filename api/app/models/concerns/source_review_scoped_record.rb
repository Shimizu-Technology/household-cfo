module SourceReviewScopedRecord
  extend ActiveSupport::Concern
  included do
    belongs_to :household
    validate :source_review_household_scope
  end

  private

  def source_review_household_scope
    self.class.reflect_on_all_associations(:belongs_to).each do |association|
      next if association.name == :household
      record = public_send(association.name)
      next unless record&.respond_to?(:household_id)
      errors.add(association.name, "must belong to this household") unless record.household_id == household_id
    end
  end
end
