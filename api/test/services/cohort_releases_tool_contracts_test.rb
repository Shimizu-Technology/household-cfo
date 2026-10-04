# frozen_string_literal: true

require "test_helper"

class CohortReleasesToolContractsTest < ActiveSupport::TestCase
  test "complete historical catalog bytes and nested values remain frozen" do
    legacy = CohortReleases::Contract.tool_registry_snapshot(version: 1)
    assert_equal "d7dad924ff936881482ff6d712fbf73e263c9e82b5f221ad367d74191d40d599",
      CohortReleases::Contract.digest(legacy)
    assert_equal "e7abdfcbc04884d60fdb92bb5e47c8a4e876983b31e6b189aa70cd8642214f84",
      CohortReleases::Contract.digest(catalogs::V2)
    assert_equal "c6fd7d270eb60542d5530a4ff021d79d343c25d1e878fb516794e1de7155d467",
      CohortReleases::Contract.digest(catalogs::V3)
    assert_equal "6212550fe9aca4c3b6c1e2cd7fd7fa3c654d1dea9cb90c826e0dffd714b1a411",
      CohortReleases::Contract.digest(catalogs::V4)
    assert_equal 73, catalogs::V4.fetch("operations").length
    assert_equal 75, catalogs::V5.fetch("operations").length
    assert_equal %w[savings.debt.stage savings.debt.approve], (catalogs::V5.fetch("operations") - catalogs::V4.fetch("operations")).map { |row| row.fetch("key") }
    assert_equal 5, catalogs.version_for_experience(CohortExperience::Schema::PILOT_SAVINGS_CONFIG)
    [ 1, 2, 3, 4, 5 ].each { |version| assert compatible?(version, CohortReleases::Contract.runtime_tool_registry_snapshot) }
    assert catalogs.runtime_compatible?(legacy, version: 1, runtime_snapshot: CohortReleases::Contract.runtime_tool_registry_snapshot)
    assert_raises(FrozenError) { catalogs::V1.fetch("operations").first["version"] = 2 }
    assert_raises(FrozenError) { catalogs::V1.fetch("modules").first.fetch("id").replace("changed") }
    legacy.fetch("operations").clear
    assert_equal 40, catalogs::V1.fetch("operations").length
  end

  test "only exact complete known catalogs are supported" do
    [ 1, 2, 3, 4, 5 ].each do |version|
      original = CohortReleases::Contract.tool_registry_snapshot(version: version)
      assert catalogs.supported_snapshot?(original, version: version)
      mutations = [
        ->(copy) { copy.fetch("operations").pop },
        ->(copy) { copy.fetch("operations").first["version"] = 2 },
        ->(copy) { copy.fetch("operations") << { "key" => "unknown.operation", "version" => 1 } },
        ->(copy) { copy.fetch("operations") << copy.fetch("operations").first.deep_dup },
        ->(copy) { copy.fetch("modules").first["core"] = false },
        ->(copy) { copy["unsupported"] = true },
        ->(copy) { copy["schema_version"] = 99 }
      ]
      mutations.each do |mutation|
        copy = original.deep_dup
        mutation.call(copy)
        refute catalogs.supported_snapshot?(copy, version: version), copy.inspect
      end
      refute catalogs.supported_snapshot?(original, version: version == 1 ? 2 : 1)
    end
    refute catalogs.supported_snapshot?(nil, version: 99)
  end

  test "unrelated additive runtime tools preserve both supported contracts" do
    runtime = CohortReleases::Contract.runtime_tool_registry_snapshot
    runtime.fetch("operations") << { "key" => "savings.example.create", "version" => 1 }
    runtime.fetch("modules") << { "id" => "example", "label" => "Example", "core" => false }
    [ 1, 2 ].each { |version| assert compatible?(version, runtime) }
  end

  test "required operation versions and module definitions must still match exactly" do
    mutations = [
      ->(copy) { copy.fetch("operations").pop },
      ->(copy) { copy.fetch("operations").first["version"] = 2 },
      ->(copy) { copy.fetch("operations").first["version"] = "1" },
      ->(copy) { copy.fetch("modules").pop },
      ->(copy) { copy.fetch("modules").first["label"] = "Changed" },
      ->(copy) { copy.fetch("modules").first["core"] = false },
      ->(copy) { copy.fetch("operations") << copy.fetch("operations").first.deep_dup },
      ->(copy) { copy.fetch("modules") << copy.fetch("modules").first.deep_dup },
      ->(copy) { copy["schema_version"] = 99 }
    ]
    mutations.each do |mutation|
      runtime = CohortReleases::Contract.tool_registry_snapshot(version: 1)
      mutation.call(runtime)
      [ 1, 2 ].each { |version| refute compatible?(version, runtime), runtime.inspect }
    end
  end

  test "savings experience requires its declared supported tool contract" do
    refute catalogs.supports_experience?(catalogs::V1, CohortExperience::Schema::SAVINGS_CONFIG)
    assert catalogs.supports_experience?(catalogs::V2, CohortExperience::Schema::SAVINGS_CONFIG)
    assert catalogs.supports_experience?(catalogs::V1, CohortExperience::Schema::DEFAULT_CONFIG)
    assert catalogs.supports_experience?(catalogs::V2, CohortExperience::Schema::DEFAULT_CONFIG)
    refute catalogs.supports_experience?(catalogs::V2, CohortExperience::Schema::SAVINGS_CONFIG.merge("experience_mode" => "unknown"))
  end

  private

  def catalogs = CohortReleases::ToolContracts

  def compatible?(version, runtime)
    catalogs.runtime_compatible?(catalogs.fetch(version), version: version, runtime_snapshot: runtime)
  end
end
