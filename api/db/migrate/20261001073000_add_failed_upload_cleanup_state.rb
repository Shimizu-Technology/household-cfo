# frozen_string_literal: true

class AddFailedUploadCleanupState < ActiveRecord::Migration[8.1]
  ORIGINAL_STATUSES = %w[uploading verifying upload_cleanup queued processing needs_review failed deletion_pending deletion_failed source_deleted].freeze
  EXPANDED_STATUSES = (ORIGINAL_STATUSES + [ "upload_cleanup_failed" ]).freeze

  def up
    remove_check_constraint :coach_content_sources, name: "coach_content_sources_status_valid"
    add_check_constraint :coach_content_sources,
      status_expression(EXPANDED_STATUSES),
      name: "coach_content_sources_status_valid"
  end

  def down
    remove_check_constraint :coach_content_sources, name: "coach_content_sources_status_valid"
    execute "UPDATE coach_content_sources SET status = 'upload_cleanup' WHERE status = 'upload_cleanup_failed'"
    add_check_constraint :coach_content_sources,
      status_expression(ORIGINAL_STATUSES),
      name: "coach_content_sources_status_valid"
  end

  private

  def status_expression(statuses)
    "status IN (#{statuses.map { |status| connection.quote(status) }.join(', ')})"
  end
end
