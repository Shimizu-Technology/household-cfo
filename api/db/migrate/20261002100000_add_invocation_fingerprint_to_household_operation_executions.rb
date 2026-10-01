class AddInvocationFingerprintToHouseholdOperationExecutions < ActiveRecord::Migration[8.1]
  def change
    add_column :household_operation_executions, :invocation_fingerprint, :string
    add_check_constraint :household_operation_executions,
      "invocation_fingerprint IS NULL OR invocation_fingerprint ~ '^[0-9a-f]{64}$'",
      name: "household_operations_invocation_fingerprint_valid"
  end
end
