# frozen_string_literal: true

module CoachOperations
  PreparedOperation = Data.define(
    :operation_key,
    :operation_version,
    :normalized_input,
    :before_snapshot,
    :predicted_after_snapshot
  )
end
