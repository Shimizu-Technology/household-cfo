# frozen_string_literal: true

require "digest"
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
    SENTRY_DSN OPENROUTER_MIA_URL
    PLAID_ENV PLAID_CLIENT_ID PLAID_SECRET PLAID_WEBHOOK_URL
    AUTH_PROVIDER WORKOS_API_KEY WORKOS_CLIENT_ID
    CLERK_SECRET_KEY CLERK_PUBLISHABLE_KEY CLERK_JWKS_URL
    SOLID_QUEUE_IN_PUMA
  ].freeze
  # libpq reads these when Rails gives it no host, or by name from a service file.
  POSTGRES_HOST_VARIABLES = %w[PGHOST PGHOSTADDR].freeze
  POSTGRES_SERVICE_VARIABLES = %w[PGSERVICE PGSERVICEFILE].freeze
  # Net::HTTP sends traffic for an allowed host through these.
  PROXY_VARIABLES = %w[http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY].freeze
  DATABASE_NAME = /\Ahousehold_cfo_ls_[a-z0-9_]+_test\z/
  LOCAL_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  MODEL_HOST = "openrouter.ai"

  module_function

  def enabled?(env = ENV)
    env["HCFO_LOCAL_STACK"] == "1"
  end

  def replay_problems(env, rails_env)
    return [] unless env["LOCAL_STACK_REPLAY"] == "1"

    issues = []
    issues << "LOCAL_STACK_REPLAY requires the guarded local stack in RAILS_ENV=test." unless enabled?(env) && rails_env.to_s == "test"
    issues << "LOCAL_STACK_REPLAY requires an empty OPENROUTER_API_KEY; recordings never use a live reader." if env["OPENROUTER_API_KEY"].present?
    issues
  end

  def check_replay!(env: ENV, rails_env: Rails.env)
    issues = replay_problems(env, rails_env)
    issues << "LOCAL_STACK_REPLAY must be explicitly enabled." unless env["LOCAL_STACK_REPLAY"] == "1"
    raise Refused, issues.join(" ") if issues.any?
  end

  # database_configs: the connection settings Rails will really use, after any
  # DATABASE_URL or <NAME>_DATABASE_URL has been merged into database.yml.
  def problems(env:, rails_env:, repo_root:, database_configs: [], shared_env_files: [])
    found = replay_problems(env, rails_env)
    found << "Run it with RAILS_ENV=test (the local stack signs in with test identities)." unless rails_env.to_s == "test"
    found << "Set STORAGE_BACKEND=local so uploads stay on this machine." unless env["STORAGE_BACKEND"] == "local"
    HOSTED_SERVICE_VARIABLES.each do |name|
      found << "#{name} must be empty (it points at a hosted service)." if env[name].present?
    end
    env.each { |name, value| found << "#{name} must be empty (it points at a hosted database)." if name.to_s.end_with?("DATABASE_URL") && value.present? }
    (POSTGRES_HOST_VARIABLES + PROXY_VARIABLES).each do |name|
      found << "#{name} must be empty or this machine." if env[name].present? && !local_host?(env[name])
    end
    POSTGRES_SERVICE_VARIABLES.each { |name| found << "#{name} must be empty (a service file can name another server)." if env[name].present? }
    found.concat(database_problems(env, database_configs))
    found.concat(model_key_problems(env, shared_env_files))
    storage = env["LOCAL_STORAGE_ROOT"].to_s
    if storage.empty?
      found << "Set LOCAL_STORAGE_ROOT to a folder outside the repository."
    elsif inside?(storage, repo_root)
      found << "LOCAL_STORAGE_ROOT must be outside the repository, so uploaded files can never be committed."
    end
    found.uniq
  end

  def database_problems(env, database_configs)
    unless env["DATABASE_TEST_NAME"].to_s.match?(DATABASE_NAME)
      return [ "DATABASE_TEST_NAME must look like household_cfo_ls_<name>_test, so a shared database is never used." ]
    end
    return [ "Rails has no database settings to check." ] if database_configs.empty?

    database_configs.flat_map do |config|
      config = config.transform_keys(&:to_sym)
      issues = []
      issues << "The #{config[:name]} database must come from database.yml, not a URL." if config[:url].present?
      issues << "The #{config[:name]} database must be #{env['DATABASE_TEST_NAME']}." unless config[:database].to_s == env["DATABASE_TEST_NAME"]
      issues << "The #{config[:name]} database must be on this machine." unless local_database_host?(config[:host]) && local_database_host?(config[:hostaddr])
      issues
    end
  end

  # The launcher sets HCFO_LOCAL_STACK_MODEL_KEY to the fingerprint of the key it
  # checked (a separate key with a credit limit). Anything else is refused,
  # including the key the shared api/.env would refill.
  def model_key_problems(env, shared_env_files)
    key = env["OPENROUTER_API_KEY"].to_s
    return [] if key.empty?

    issues = []
    issues << "OPENROUTER_API_KEY must be empty unless bin/local-stack checked it is a separate key with a credit limit." unless env["HCFO_LOCAL_STACK_MODEL_KEY"] == fingerprint(key)
    shared = shared_env_files.filter_map { |path| shared_model_key(path) }
    issues << "OPENROUTER_API_KEY is the shared key production uses." if shared.include?(key)
    issues
  end

  def shared_model_key(path)
    return unless File.file?(path)

    require "dotenv"
    Dotenv.parse(path)["OPENROUTER_API_KEY"].presence
  end

  def fingerprint(key) = Digest::SHA256.hexdigest(key.to_s)

  # libpq accepts a comma-separated list and tries each in turn, so every entry must be a socket folder or this machine.
  # An empty entry is libpq's default local socket.
  def local_database_host?(value)
    hosts = value.to_s.split(",", -1).map(&:strip)
    hosts.empty? || hosts.all? { |host| host.empty? || host.start_with?("/") || local_host?(host) }
  end

  # "localhost", "localhost:5432", "127.0.0.1", "::1", "[::1]:3128" or a URL naming one of them.
  def local_host?(value)
    host = value.to_s.strip.downcase
    host = URI.parse(host).host.to_s if host.include?("://")
    if host.start_with?("[")
      host = host[1...host.index("]")] if host.include?("]")
    elsif host.count(":") == 1
      host = host.split(":").first.to_s
    end
    host.in?(LOCAL_HOSTS)
  rescue URI::InvalidURIError
    false
  end

  def allowed_hosts(env = ENV)
    hosts = LOCAL_HOSTS.dup
    hosts << MODEL_HOST if env["OPENROUTER_API_KEY"].present? && env["HCFO_LOCAL_STACK_MODEL_KEY"] == fingerprint(env["OPENROUTER_API_KEY"])
    hosts
  end

  def check_host!(host, env = ENV)
    name = host.to_s.downcase.delete_prefix("[").delete_suffix("]")
    return if allowed_hosts(env).include?(name)

    Rails.logger&.error("[local-stack] blocked a connection to #{name}")
    raise BlockedHost, "The local stack only connects to this machine#{" and #{MODEL_HOST}" if allowed_hosts(env).include?(MODEL_HOST)}; blocked #{name}."
  end

  def effective_database_configs(application = Rails.application, rails_env = Rails.env)
    require "active_record"
    require "active_record/database_configurations"
    ActiveRecord::DatabaseConfigurations.new(application.config.database_configuration).configs_for(env_name: rails_env.to_s, include_hidden: true).map do |config|
      config.configuration_hash.merge(name: config.name, url: config.respond_to?(:url) ? config.url : nil)
    end
  end

  def install!(env: ENV, rails_env: Rails.env, repo_root: Rails.root.parent, application: Rails.application)
    found = problems(env: env, rails_env: rails_env, repo_root: repo_root, database_configs: effective_database_configs(application, rails_env),
      shared_env_files: [ application.root.join(".env").to_s ])
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

    # A proxy would receive the connection instead of the host it names, so both must be this machine.
    def connect
      LocalStack.check_host!(address)
      LocalStack.check_host!(proxy_address) if proxy?
      super
    end
  end
end
