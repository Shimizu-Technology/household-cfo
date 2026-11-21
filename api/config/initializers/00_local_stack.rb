# frozen_string_literal: true

# Runs first, before anything else can open a connection. See lib/local_stack.rb
# and docs/testing/local-stack.md.
if ENV["LOCAL_STACK_REPLAY"] == "1"
  require Rails.root.join("lib/local_stack").to_s
  LocalStack.check_replay!
end

if ENV["HCFO_LOCAL_STACK"] == "1"
  require Rails.root.join("lib/local_stack").to_s
  LocalStack.install!
end
