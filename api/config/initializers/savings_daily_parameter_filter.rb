# These private values must not enter request logs or model inspection output.
# Generic operation executions and audit mirrors are separately redacted by Runner.
Rails.application.config.filter_parameters += %i[
  feeling_then feeling_now amount_cents merchant purchased_on local_on
  splits spending_state snapshot
]
