# frozen_string_literal: true

module CoachOperations
  module Registry
    OPERATIONS = {
      CohortReleaseSeal::KEY => CohortReleaseSeal,
      CohortReleaseRestore::KEY => CohortReleaseRestore,
      CohortRolloutPlan::KEY => CohortRolloutPlan,
      CohortRolloutAdvance::KEY => CohortRolloutAdvance,
      CohortRolloutPause::KEY => CohortRolloutPause,
      CohortRolloutResume::KEY => CohortRolloutResume,
      CohortRolloutCancel::KEY => CohortRolloutCancel,
      CohortRolloutRollback::KEY => CohortRolloutRollback
    }.freeze

    module_function

    def fetch(key, version:)
      operation = OPERATIONS.fetch(key.to_s) { raise KeyError, "Unknown coach operation" }
      raise KeyError, "Unknown coach operation version" unless operation::VERSION == Integer(version, exception: false)

      operation
    end

    def operations
      OPERATIONS.dup
    end
  end
end
