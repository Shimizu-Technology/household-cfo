require "test_helper"
require Rails.root.join("db/migrate/20261001031300_expand_mia_user_message_length").to_s

class ExpandMiaUserMessageLengthTest < ActiveSupport::TestCase
  test "rollback is explicit because existing participant messages may exceed the old limit" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      ExpandMiaUserMessageLength.new.down
    end

    assert_includes error.message, "above 2,000 characters"
    assert_includes error.message, "existing data"
  end
end
