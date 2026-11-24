# Bills join the financial-picture write guard every other financial table uses, so a bill write prepared
# before a restart can't land in the new picture. A create also keeps its request key, so a retried Save
# returns the bill it already saved instead of adding another.
class GuardBillsAndAddIdempotency < ActiveRecord::Migration[8.0]
  def up
    add_column :bills, :idempotency_key, :string, limit: 255
    add_index :bills, %i[household_id financial_generation idempotency_key], unique: true, where: "idempotency_key IS NOT NULL", name: "index_bills_on_household_and_idempotency_key"
    execute "CREATE TRIGGER bills_financial_picture_guard BEFORE INSERT OR UPDATE ON bills FOR EACH ROW EXECUTE FUNCTION financial_picture_write_guard()"
  end

  def down
    execute "DROP TRIGGER bills_financial_picture_guard ON bills"
    remove_index :bills, name: "index_bills_on_household_and_idempotency_key"
    remove_column :bills, :idempotency_key
  end
end
