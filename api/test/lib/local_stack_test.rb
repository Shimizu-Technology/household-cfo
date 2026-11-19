require "test_helper"
require "tmpdir"
require Rails.root.join("lib/local_stack").to_s

class LocalStackTest < ActiveSupport::TestCase
  REPO = "/work/household-cfo"
  DB = "household_cfo_ls_t1_local_stack_ab12cd_test"

  def safe_env(overrides = {})
    {
      "HCFO_LOCAL_STACK" => "1",
      "STORAGE_BACKEND" => "local",
      "DATABASE_TEST_NAME" => DB,
      "LOCAL_STORAGE_ROOT" => "/home/leon/.local/state/household-cfo/local-stack/t1/storage"
    }.merge(overrides)
  end

  def local_database(overrides = {}) = { name: "primary", database: DB, host: nil, url: nil }.merge(overrides)

  def problems(env, rails_env: "test", database_configs: [ local_database ], shared_env_files: [])
    LocalStack.problems(env: env, rails_env: rails_env, repo_root: REPO, database_configs: database_configs, shared_env_files: shared_env_files)
  end

  test "a clean local environment passes" do
    assert_empty problems(safe_env)
  end

  test "refuses anything but the test environment" do
    assert_match(/RAILS_ENV=test/, problems(safe_env, rails_env: "production").join)
    assert_match(/RAILS_ENV=test/, problems(safe_env, rails_env: "development").join)
  end

  test "refuses real storage and every hosted service key" do
    assert_match(/STORAGE_BACKEND=local/, problems(safe_env("STORAGE_BACKEND" => "s3")).join)
    LocalStack::HOSTED_SERVICE_VARIABLES.each do |name|
      found = problems(safe_env(name => "set-by-dotenv"))
      assert_equal 1, found.size, name
      assert_match(/\A#{name} must be empty/, found.first)
    end
  end

  test "the launcher blanks or unsets exactly what the guard refuses" do
    script = Rails.root.parent.join("bin/local-stack").read
    blanked = script[/^HOSTED_API=\((.*?)\)/m, 1].split
    unset = script[/^UNSET_ALWAYS=\((.*?)\)/m, 1].split
    assert_equal LocalStack::HOSTED_SERVICE_VARIABLES.sort, blanked.sort
    assert_equal (LocalStack::POSTGRES_HOST_VARIABLES + LocalStack::POSTGRES_SERVICE_VARIABLES + LocalStack::PROXY_VARIABLES).sort, unset.sort
    assert_includes script, "DATABASE_URL)=", "Every *DATABASE_URL is unset, not only the ones named here"
  end

  test "refuses any database URL, whatever its name" do
    %w[DATABASE_URL PRIMARY_DATABASE_URL CACHE_DATABASE_URL QUEUE_DATABASE_URL CABLE_DATABASE_URL].each do |name|
      assert_match(/#{name} must be empty/, problems(safe_env(name => "postgres://db.example.com/prod")).join, name)
    end
  end

  test "checks the database Rails really resolves, not only the variables" do
    assert_match(/must come from database.yml/, problems(safe_env, database_configs: [ local_database(url: "postgres://db.example.com/prod") ]).join)
    assert_match(/must be #{DB}/, problems(safe_env, database_configs: [ local_database(database: "household_cfo_api_production") ]).join)
    assert_match(/on this machine/, problems(safe_env, database_configs: [ local_database(host: "db.example.neon.tech") ]).join)
    assert_match(/no database settings/, problems(safe_env, database_configs: []).join)
    assert_empty problems(safe_env, database_configs: [ local_database(host: "127.0.0.1") ])
    assert_empty problems(safe_env, database_configs: [ local_database(host: "/tmp") ])
  end

  test "a PRIMARY_DATABASE_URL in the environment shows up in what Rails would use" do
    previous = ENV.fetch("PRIMARY_DATABASE_URL", nil)
    ENV["PRIMARY_DATABASE_URL"] = "postgres://db.example.com/prod_db"
    configs = LocalStack.effective_database_configs(Rails.application, "test")
    assert_equal [ "prod_db" ], configs.map { |config| config[:database] }
    found = problems(safe_env("PRIMARY_DATABASE_URL" => ENV["PRIMARY_DATABASE_URL"]), database_configs: configs).join("\n")
    assert_match(/must come from database.yml/, found)
    assert_match(/on this machine/, found)
  ensure
    previous ? ENV["PRIMARY_DATABASE_URL"] = previous : ENV.delete("PRIMARY_DATABASE_URL")
  end

  test "refuses a shared or badly named database" do
    %w[household_cfo_api_test household_cfo_api_qa household_cfo_api_production].each do |name|
      assert_match(/DATABASE_TEST_NAME/, problems(safe_env("DATABASE_TEST_NAME" => name)).join, name)
    end
    assert_match(/DATABASE_TEST_NAME/, problems(safe_env.except("DATABASE_TEST_NAME")).join)
  end

  test "refuses Postgres settings and proxies that point elsewhere" do
    assert_match(/PGHOST must be empty or this machine/, problems(safe_env("PGHOST" => "db.example.neon.tech")).join)
    assert_match(/PGHOSTADDR/, problems(safe_env("PGHOSTADDR" => "203.0.113.7")).join)
    assert_match(/PGSERVICE must be empty/, problems(safe_env("PGSERVICE" => "prod")).join)
    assert_match(/HTTPS_PROXY/, problems(safe_env("HTTPS_PROXY" => "http://proxy.example.com:3128")).join)
    assert_empty problems(safe_env("PGHOST" => "localhost", "http_proxy" => "http://127.0.0.1:8080"))
  end

  test "a model key needs the fingerprint of the key the launcher checked" do
    key = "sk-or-capped-local"
    assert_match(/OPENROUTER_API_KEY must be empty/, problems(safe_env("OPENROUTER_API_KEY" => "sk-or-shared")).join)
    assert_match(/OPENROUTER_API_KEY must be empty/, problems(safe_env("OPENROUTER_API_KEY" => key, "HCFO_LOCAL_STACK_MODEL_KEY" => "checked")).join)
    assert_empty problems(safe_env("OPENROUTER_API_KEY" => key, "HCFO_LOCAL_STACK_MODEL_KEY" => LocalStack.fingerprint(key)))
  end

  test "refuses the shared key from api/.env however that file writes it" do
    Dir.mktmpdir do |dir|
      shared = File.join(dir, ".env")
      File.write(shared, "OPENROUTER_API_KEY=sk-or-shared # the production key\n")
      env = safe_env("OPENROUTER_API_KEY" => "sk-or-shared", "HCFO_LOCAL_STACK_MODEL_KEY" => LocalStack.fingerprint("sk-or-shared"))
      assert_match(/shared key production uses/, problems(env, shared_env_files: [ shared ]).join)
      other = safe_env("OPENROUTER_API_KEY" => "sk-or-capped", "HCFO_LOCAL_STACK_MODEL_KEY" => LocalStack.fingerprint("sk-or-capped"))
      assert_empty problems(other, shared_env_files: [ shared, File.join(dir, "missing.env") ])
    end
  end

  test "uploaded files must live outside the repository" do
    assert_match(/LOCAL_STORAGE_ROOT to a folder/, problems(safe_env.except("LOCAL_STORAGE_ROOT")).join)
    assert_match(/outside the repository/, problems(safe_env("LOCAL_STORAGE_ROOT" => "#{REPO}/api/storage")).join)
    assert_empty problems(safe_env("LOCAL_STORAGE_ROOT" => "#{REPO}-other/storage"))
  end

  test "install refuses with every problem listed" do
    error = assert_raises(LocalStack::Refused) do
      LocalStack.install!(env: safe_env("RESEND_API_KEY" => "re_x", "STORAGE_BACKEND" => "s3"), rails_env: "test", repo_root: REPO)
    end
    assert_match(/RESEND_API_KEY/, error.message)
    assert_match(/STORAGE_BACKEND/, error.message)
  end

  test "only this machine is reachable, plus the model host once its key is checked" do
    LocalStack.check_host!("127.0.0.1", safe_env)
    LocalStack.check_host!("localhost", safe_env)
    LocalStack.check_host!("[::1]", safe_env)
    %w[household-cfo.s3.ap-southeast-2.amazonaws.com api.resend.com api.workos.com openrouter.ai].each do |host|
      assert_raises(LocalStack::BlockedHost, host) { LocalStack.check_host!(host, safe_env) }
    end
    checked = safe_env("OPENROUTER_API_KEY" => "sk-or-capped", "HCFO_LOCAL_STACK_MODEL_KEY" => LocalStack.fingerprint("sk-or-capped"))
    LocalStack.check_host!("openrouter.ai", checked)
    assert_raises(LocalStack::BlockedHost) { LocalStack.check_host!("api.resend.com", checked) }
    assert_raises(LocalStack::BlockedHost) { LocalStack.check_host!("openrouter.ai", checked.merge("HCFO_LOCAL_STACK_MODEL_KEY" => "checked")) }
  end

  test "the network guard stops a real connection, and a remote proxy, before either opens" do
    guarded = Class.new(Net::HTTP) { prepend LocalStack::NetworkGuard }
    previous = ENV.to_h.slice("OPENROUTER_API_KEY", "HCFO_LOCAL_STACK_MODEL_KEY")
    ENV.delete("OPENROUTER_API_KEY")
    error = assert_raises(LocalStack::BlockedHost) { guarded.new("api.resend.com", 443).start }
    assert_match(/blocked api.resend.com/, error.message)
    error = assert_raises(LocalStack::BlockedHost) { guarded.new("127.0.0.1", 3300, "proxy.example.com", 3128).start }
    assert_match(/blocked proxy.example.com/, error.message)
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end
end
