class CreateBills < ActiveRecord::Migration[8.0]
  def change
    create_table :bills do |t|
      t.references :household, null: false, foreign_key: true
      t.references :budget_category, foreign_key: true
      t.integer :financial_generation, null: false, default: 0
      t.string :name, null: false
      t.bigint :amount_cents, null: false
      t.date :due_on, null: false
      t.integer :repeat_months
      t.boolean :must_pay, null: false, default: true
      t.boolean :estimate, null: false, default: false
      t.timestamps
    end
  end
end
