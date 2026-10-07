# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :code, :state, :code_verifier, :cookie, :authorization_url, :redirect_url,
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :file, :image, :document, :file_data, :source_data, :extracted_text, :evidence_excerpt,
  :candidate_content, :draft_content, :content, :filename, :title, :topics, :evidence_locator,
  :checksum_sha256, :url, :encrypted_url,
  :signed_cents, :target_cents, :effective_on, :cutoff_on, :funding_source, :reason,
  :evidence_supported_cents, :known_zero,
  :facts, :statement_facts, :projection, :members, :request, :input,
  :message, :selected_records, :recipient_user_id, :granted, :expires_at,
  :merchant, :feeling_then, :feeling_now, :reflection, :spending_reason, :purchase_amount_cents, :signed_amount_cents,
  :spending_changes, :planned_reduction_cents, :baseline_digest, :description, :amount_cents
]
