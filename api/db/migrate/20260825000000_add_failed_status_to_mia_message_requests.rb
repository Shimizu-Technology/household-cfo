class AddFailedStatusToMiaMessageRequests < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :mia_message_requests, name: "mia_message_requests_status_valid"
    add_check_constraint :mia_message_requests,
                         "status IN ('processing', 'completed', 'failed')",
                         name: "mia_message_requests_status_valid"
  end
end
