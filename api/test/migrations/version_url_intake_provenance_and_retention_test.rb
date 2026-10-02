# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261002202000_version_url_intake_provenance_and_retention")

class VersionUrlIntakeProvenanceAndRetentionTest < ActiveSupport::TestCase
  test "rollback is explicit because redacted intakes and versioned provenance cannot use the old schema" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      VersionUrlIntakeProvenanceAndRetention.new.down
    end

    assert_match(/redacted URL intake rows/, error.message)
  end
end
