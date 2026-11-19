# frozen_string_literal: true

require "net/http"
require "pathname"

# The local full stack (bin/local-stack) runs the real API on a laptop. It must
# never reach anything hosted: no real S3 bucket, no email, no production
# database, and no model key that production also spends. dotenv refills any
# variable that is missing from the shell, so a clean shell is not enough; this
# guard checks what Rails actually booted with and refuses to start otherwise.
module LocalStack
  class Refused < StandardError; end
  class BlockedHost < StandardError; end

  # Hosted services a local run must not configure. Blank is the only safe value.
  HOSTED_SERVICE_VARIABLES = %w[
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_S3_BUCKET
    RESEND_API_KEY RESEND_FROM_EMAIL MAILER_FROM_EMAIL OPS_ALERT_EMAILS
    REMINDERS_EMAIL_ENABLED SMTP_ADDRESS SMTP_USERNAME SMTP_PASSWORD
    SENTRY_DSN
    PLAID_CLIENT_ID PLAID_SECRET PLAID_WEBHOOK_URL
    DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL
    AUTH_PROVIDER WORKOS_API_KEY WORKOS_CLIENT_ID
    CLERK_SECRET_KEY CLERK_PUBLISHABLE_KEY CLERK_JWKS_URL
    SOLID_QUEUE_IN_PUMA
  ].freeze
  DATABASE_NAME = /\Ahousehold_cfo_ls_[a-z0-9_]+_test\z/
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  MODEL_HOST = "openrouter.ai"
  # bin/local-stack sets this only after checking the key is not production's
  # and has a credit limit.
  MODEL_KEY_CHECKED = "checked"

  module_function

  def enabled?(env = ENV)
    env["HCFO_LOCAL_STACK"] == "1"
  end

  def problems(env:, rails_env:, repo_root:)
    found = []
    found << "Run it with RAILS_ENV=test (the local stack signs in with test identities)." unless rails_env.to_s == "test"
    found << "Set STORAGE_BACKEND=local so uploads stay on this machine." unless env["STORAGE_BACKEND"] == "local"
    HOSTED_SERVICE_VARIABLES.each do |name|
      found << "#{name} must be empty (it points at a hosted service)." if env[name].present?
    end
    unless env["DATABASE_TEST_NAME"].to_s.match?(DATABASE_NAME)
      found << "DATABASE_TEST_NAME must look like household_cfo_ls_<name>_test, so a shared database is never used."
    end
    host = env["DATABASE_HOST"].to_s
    unless host.empty? || host.in?(LOCAL_HOSTS) || host.start_with?("/")
      found << "DATABASE_HOST must be this machine."
    end
    if env["OPENROUTER_API_KEY"].present? && env["HCFO_LOCAL_STACK_MODEL_KEY"] != MODEL_KEY_CHECKED
      found << "OPENROUTER_API_KEY must be empty unless bin/local-stack checked it is a separate key with a credit limit."
    end
    storage = env["LOCAL_STORAGE_ROOT"].to_s
    if storage.empty?
      found << "Set LOCAL_STORAGE_ROOT to a folder outside the repository."
    elsif inside?(storage, repo_root)
      found << "LOCAL_STORAGE_ROOT must be outside the repository, so uploaded files can never be committed."
    end
    found
  end

  def allowed_hosts(env = ENV)
    hosts = LOCAL_HOSTS.dup
    hosts << MODEL_HOST if env["OPENROUTER_API_KEY"].present? && env["HCFO_LOCAL_STACK_MODEL_KEY"] == MODEL_KEY_CHECKED
    hosts
  end

  def check_host!(host, env = ENV)
    name = host.to_s.downcase.delete_prefix("[").delete_suffix("]")
    return if allowed_hosts(env).include?(name)

    Rails.logger&.error("[local-stack] blocked a connection to #{name}")
    raise BlockedHost, "The local stack only connects to this machine#{" and #{MODEL_HOST}" if allowed_hosts(env).include?(MODEL_HOST)}; blocked #{name}."
  end

  def install!(env: ENV, rails_env: Rails.env, repo_root: Rails.root.parent, application: Rails.application)
    found = problems(env: env, rails_env: rails_env, repo_root: repo_root)
    raise Refused, "The local stack refused to start:\n- #{found.join("\n- ")}" if found.any?

    Net::HTTP.prepend(NetworkGuard) unless Net::HTTP.ancestors.include?(NetworkGuard)
    mail_root = Pathname.new(env["LOCAL_STORAGE_ROOT"]).parent.join("mail").to_s
    application.config.after_initialize do
      # Jobs (statement extraction, projections) finish while the browser waits.
      ActiveJob::Base.queue_adapter = :async
    end
    # Any mail ActionMailer would send is written to a file, never delivered.
    ActiveSupport.on_load(:action_mailer) do
      self.delivery_method = :file
      self.file_settings = { location: mail_root }
    end
  end

  def inside?(path, root)
    expanded = Pathname.new(path).expand_path
    repo = Pathname.new(root).expand_path
    expanded == repo || expanded.to_s.start_with?("#{repo}/")
  end

  module NetworkGuard
    private

    def connect
      LocalStack.check_host!(address)
      super
    end
  end
end
