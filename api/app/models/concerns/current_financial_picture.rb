module CurrentFinancialPicture
  extend ActiveSupport::Concern

  included do
    scope :current_picture, -> {
      where("#{table_name}.financial_generation = (SELECT financial_generation FROM households WHERE households.id = #{table_name}.household_id)")
    }
    before_validation :assign_financial_generation, on: :create
    before_create :assign_financial_generation
  end

  def current_financial_picture?
    financial_generation == Household.where(id: household_id).pick(:financial_generation)
  end

  private

  def assign_financial_generation
    self.financial_generation = if FinancialPicture.household_id == household_id && !FinancialPicture.generation.nil?
      FinancialPicture.generation
    else
      Household.where(id: household_id).pick(:financial_generation) || 0
    end
  end
end
