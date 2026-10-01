class ValidateMiaActionItemOperationConstraints < ActiveRecord::Migration[8.1]
  def up
    validate_check_constraint :mia_action_items, name: "mia_action_items_operation_identity_complete"
    validate_check_constraint :mia_action_items, name: "mia_action_items_prepared_operation_object"
  end

  def down
    # Validation state cannot be reversed without dropping and recreating the
    # constraints. The preceding migration owns their lifecycle.
  end
end
