# frozen_string_literal: true

require "test_helper"
require_relative "../support/persona_test_helper"

class CohortReleaseContractCompatibilityTest < ActiveSupport::TestCase
  include PersonaTestHelper
  test "manifest v1 canonical bytes and digests stay frozen" do
    cohort = Data.define(:id, :coach_workspace_id).new(id: 17, coach_workspace_id: 9)
    persona_snapshot = {
      "mode" => "neutral_builtin",
      "builtin_id" => "neutral-v1",
      "data" => { "name" => "Mia", "voice" => { "tone" => "calm" } }
    }
    experience_snapshot = {
      "mode" => "safe_default",
      "configuration_id" => 23,
      "config" => {
        "schema_version" => 1,
        "optional_modules" => { "cfo_filter" => false, "optionality" => false }
      }
    }
    tool_registry_snapshot = {
      "schema_version" => 1,
      "modules" => [ { "id" => "budget", "core" => true } ],
      "operations" => [ { "key" => "profile.setup.update", "version" => 1 } ]
    }
    expected_bundle_digest = "cb1395933d32ea1d6a55067683ec675cae885901b5a57073fda866699784bb30"

    bundle = CohortReleases::Contract.bundle_v1(
      cohort: cohort,
      persona_snapshot: persona_snapshot,
      experience_snapshot: experience_snapshot,
      tool_registry_snapshot: tool_registry_snapshot
    )
    manifest = CohortReleases::Contract.manifest_v1(
      release_number: 3,
      publication_source: "legacy_backfill",
      event_type: "reconciliation",
      released_by_user_id: nil,
      actor_role_snapshot: nil,
      source_release_id: nil,
      request_key: "legacy-backfill-v1",
      request_fingerprint: "f" * 64,
      released_at: Time.iso8601("2026-10-03T01:02:03.456789Z"),
      bundle_digest: expected_bundle_digest
    )

    expected_bundle_json = <<~JSON.chomp
      {"coach_workspace_id":9,"cohort_id":17,"experience":{"mode":"safe_default","snapshot":{"config":{"optional_modules":{"cfo_filter":false,"optionality":false},"schema_version":1},"configuration_id":23,"mode":"safe_default"},"snapshot_digest":"f13322edbfa2fe23f9f2c9c613d2c6f5947c51ea12b3705a2517369a00990ac2"},"persona":{"mode":"neutral_builtin","snapshot":{"builtin_id":"neutral-v1","data":{"name":"Mia","voice":{"tone":"calm"}},"mode":"neutral_builtin"},"snapshot_digest":"e00405fcb1941fcff02ee2062fdcc7cb8cbc65479a129f5fc2f0337b853dbda5"},"schema":"cohort_release_manifest_v1","tool_registry":{"snapshot":{"modules":[{"core":true,"id":"budget"}],"operations":[{"key":"profile.setup.update","version":1}],"schema_version":1},"snapshot_digest":"d74edf6225f2ef3d2bfabbbf0bbbb366a9586fa95266fbc04cafa97e44aa625e","version":1}}
    JSON
    expected_manifest_json = <<~JSON.chomp
      {"actor_role_snapshot":null,"bundle_digest":"cb1395933d32ea1d6a55067683ec675cae885901b5a57073fda866699784bb30","event_type":"reconciliation","publication_source":"legacy_backfill","release_number":3,"released_at":"2026-10-03T01:02:03.456789Z","released_by_user_id":null,"request_fingerprint":"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff","request_key":"legacy-backfill-v1","schema":"cohort_release_manifest_v1","source_release_id":null}
    JSON

    assert_equal expected_bundle_json, JSON.generate(bundle)
    assert_equal expected_bundle_digest, CohortReleases::Contract.digest(bundle)
    assert_equal expected_manifest_json, JSON.generate(manifest)
    assert_equal "d463df28d19c13556fe3336fc0e3c29df1a9cc7b4c742c9f84bea4d5fc473ffc",
      CohortReleases::Contract.digest(manifest)
  end


  test "historical v1 evidence remains valid during the expand deployment" do
    owner = persona_user
    cohort = Cohort.create!(name: "Historical v1 #{SecureRandom.hex(4)}", created_by_user: owner)
    CohortReleases::LegacyReconciler.new(scope: Cohort.where(id: cohort.id)).call
    current_release = cohort.cohort_releases.find_by!(request_key: CohortRelease::LEGACY_RECONCILIATION_REQUEST_KEY)
    historical_attributes = historical_v1_attributes(current_release)

    CohortRelease.insert!(historical_attributes)
    release = CohortRelease.find_by!(request_key: historical_attributes.fetch("request_key"))

    assert_equal CohortReleases::Contract::V1_SCHEMA, release.manifest_schema
    assert_nil release.brand_snapshot
    report = release.integrity_report
    assert report.fetch(:valid), report.fetch(:errors).inspect
    assert report.fetch(:runtime_compatible), report.fetch(:errors).inspect
    assert_equal "Household CFO", Branding::RuntimeResolver.for_release(release).dig(:config, "product_name")
  end

  test "a near-limit Unicode brand configuration fits the immutable snapshot wrapper" do
    config = Branding::Schema::DEFAULT_CONFIG.deep_dup
    config.merge!(
      "product_name" => "💰" * 80,
      "short_name" => "🌴" * 32,
      "organization_name" => "🏠" * 100,
      "participant_role_term" => "👥" * 48,
      "powered_by_name" => "✨" * 80,
      "tagline" => "🌺" * 180,
      "welcome_heading" => "🌊" * 120,
      "welcome_description" => "🧭" * 320,
      "logo_url" => maximum_https_url("logo"),
      "favicon_url" => maximum_https_url("favicon"),
      "support" => {
        "label" => "☎" * 80,
        "email" => "support@example.com",
        "url" => maximum_https_url("support")
      },
      "footer" => {
        "text" => "📘" * 500,
        "privacy_url" => maximum_https_url("privacy"),
        "terms_url" => maximum_https_url("terms")
      }
    )

    shrink_url_to_fit_brand_config!(config, target_bytes: 16_217)
    assert_empty Branding::Schema.errors(config)
    config_bytes = jsonb_text_bytes(Branding::Schema.normalize(config))
    assert_operator config_bytes, :<=, 16_384
    assert_operator config_bytes, :>, 16_000
    snapshot = CohortReleases::Contract.published_brand_snapshot(
      version: Data.define(:workspace_brand_configuration_id, :id, :version_number, :config, :config_digest).new(
        workspace_brand_configuration_id: 1,
        id: 2,
        version_number: 3,
        config: config,
        config_digest: Branding::Schema.digest(config)
      )
    )

    snapshot_bytes = jsonb_text_bytes(snapshot)
    assert_operator snapshot_bytes, :>, 16_384
    assert_operator snapshot_bytes, :<=, 32_768
  end

  private

  def maximum_https_url(label)
    prefix = "https://example.com/#{label}/"
    prefix + ("a" * (2_048 - prefix.length))
  end

  def shrink_url_to_fit_brand_config!(config, target_bytes:)
    normalized_bytes = jsonb_text_bytes(Branding::Schema.normalize(config))
    overflow = normalized_bytes - target_bytes
    return unless overflow.positive?

    url = config.dig("footer", "terms_url")
    config["footer"]["terms_url"] = url.first(url.length - overflow)
  end

  def jsonb_text_bytes(value)
    quoted_json = ApplicationRecord.connection.quote(JSON.generate(value))
    ApplicationRecord.connection.select_value("SELECT octet_length(#{quoted_json}::jsonb::text)").to_i
  end

  def historical_v1_attributes(release)
    bundle = CohortReleases::Contract.bundle_v1(
      cohort: release.cohort,
      persona_snapshot: release.persona_snapshot,
      experience_snapshot: release.experience_snapshot,
      tool_registry_snapshot: release.tool_registry_snapshot
    )
    bundle_digest = CohortReleases::Contract.digest(bundle)
    request_key = "historical-v1-#{SecureRandom.hex(4)}"
    request_fingerprint = Digest::SHA256.hexdigest(request_key)
    released_at = Time.current
    manifest = CohortReleases::Contract.manifest_v1(
      release_number: release.release_number + 1,
      publication_source: "system",
      event_type: "reconciliation",
      released_by_user_id: nil,
      actor_role_snapshot: nil,
      source_release_id: nil,
      request_key: request_key,
      request_fingerprint: request_fingerprint,
      released_at: released_at,
      bundle_digest: bundle_digest
    )

    release.attributes.except("id").merge(
      "release_number" => release.release_number + 1,
      "publication_source" => "system",
      "manifest_schema" => CohortReleases::Contract::V1_SCHEMA,
      "brand_mode" => nil,
      "workspace_brand_version_id" => nil,
      "brand_snapshot" => nil,
      "brand_snapshot_digest" => nil,
      "bundle" => bundle,
      "bundle_digest" => bundle_digest,
      "manifest" => manifest,
      "manifest_digest" => CohortReleases::Contract.digest(manifest),
      "request_key" => request_key,
      "request_fingerprint" => request_fingerprint,
      "released_at" => released_at,
      "created_at" => released_at,
      "updated_at" => released_at
    )
  end
end
