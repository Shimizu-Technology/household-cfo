class ApplicationController < ActionController::API
  # Fallback for controllers that do not rescue their own missing records.
  # Never echo the exception message: it can contain the SQL WHERE clause.
  rescue_from ActiveRecord::RecordNotFound do |error|
    Rails.logger.info("[RecordNotFound] #{error.class}: #{error.message.to_s.truncate(300)}")
    render json: { errors: [ "Not found" ], code: "not_found" }, status: :not_found
  end
end
