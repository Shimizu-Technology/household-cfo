require "test_helper"
require Rails.root.join("lib/local_stack").to_s

class LocalStackTest < ActiveSupport::TestCase
  REPO = "/work/household-cfo"

  def safe_env(overrides = {})
    {
      "HCFO_LOCAL_STACK" => "1",
      "STORAGE_BACKEND" => "local",
      "DATABASE_TEST_NAME" => "household_cfo_ls_t1_local_stack_test",
      "LOCAL_STORAGE_ROOT" => "/home/leon/.local/state/household-cfo/local-stack/t1/storage"
    }.merge(overrides)
  end

  def problems(env, rails_env: "test")
    LocalStack.problems(env: env, rails_env: rails_env, repo_root: REPO)
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

  test "the launcher blanks exactly the variables the guard refuses" do
    script = Rails.root.parent.join("bin/local-stack").read
    launcher = script[/^HOSTED_API=\((.*?)\)/m, 1].split + script[/^DATABASE_URLS=\((.*?)\)/m, 1].split
    assert_equal LocalStack::HOSTED_SERVICE_VARIABLES.sort, launcher.sort
  end

  test "refuses a shared or remote database" do
    %w[household_cfo_api_test household_cfo_api_qa household_cfo_api_production].each do |name|
      assert_match(/DATABASE_TEST_NAME/, problems(safe_env("DATABASE_TEST_NAME" => name)).join, name)
    end
    assert_match(/DATABASE_TEST_NAME/, problems(safe_env.except("DATABASE_TEST_NAME")).join)
    assert_match(/DATABASE_HOST/, problems(safe_env("DATABASE_HOST" => "db.example.neon.tech")).join)
    assert_empty problems(safe_env("DATABASE_HOST" => "127.0.0.1"))
    assert_empty problems(safe_env("DATABASE_HOST" => "/tmp"))
  end

  test "a model key needs the launcher's check" do
    assert_match(/OPENROUTER_API_KEY/, problems(safe_env("OPENROUTER_API_KEY" => "sk-or-shared")).join)
    assert_empty problems(safe_env("OPENROUTER_API_KEY" => "sk-or-capped", "HCFO_LOCAL_STACK_MODEL_KEY" => "checked"))
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
    checked = safe_env("OPENROUTER_API_KEY" => "sk-or-capped", "HCFO_LOCAL_STACK_MODEL_KEY" => "checked")
    LocalStack.check_host!("openrouter.ai", checked)
    assert_raises(LocalStack::BlockedHost) { LocalStack.check_host!("api.resend.com", checked) }
  end

  test "the network guard stops a real connection before it opens" do
    guarded = Class.new(Net::HTTP) { prepend LocalStack::NetworkGuard }
    previous = ENV.to_h.slice("OPENROUTER_API_KEY", "HCFO_LOCAL_STACK_MODEL_KEY")
    ENV.delete("OPENROUTER_API_KEY")
    error = assert_raises(LocalStack::BlockedHost) { guarded.new("api.resend.com", 443).start }
    assert_match(/blocked api.resend.com/, error.message)
  ensure
    previous&.each { |name, value| ENV[name] = value }
  end
end
