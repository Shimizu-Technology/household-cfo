class SourceEconomicGroup < ApplicationRecord
  include CurrentFinancialPicture
  include SourceReviewScopedRecord
  belongs_to :approved_version, class_name: "SourceEconomicGroupVersion", optional: true
  validate :approved_version_belongs_to_group
  has_many :source_economic_group_versions

  private

  def approved_version_belongs_to_group
    errors.add(:approved_version, "must belong to this group") if approved_version && approved_version.source_economic_group_id != id
  end
end
