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
      supported = operation.const_defined?(:SUPPORTED_VERSIONS) ? operation::SUPPORTED_VERSIONS : [ operation::VERSION ]
      raise KeyError, "Unknown coach operation version" unless Integer(version, exception: false).in?(supported)

      operation
    end

    def operations
      OPERATIONS.dup
    end
  end
end
