# frozen_string_literal: true

require "digest"

module HouseholdFinance
  class MiaProviderAdmission
    PROVIDER = "openrouter_mia"
    DEFAULT_LIMIT = 4
    MAX_LIMIT = 16
    DEFAULT_WAIT_MS = 1_000
    MAX_WAIT_MS = 5_000
    POLL_INTERVAL_SECONDS = 0.05
    DENIED_EVENT = "mia.provider_admission_denied"
    DENIED_MESSAGE = "Mia provider admission denied; deterministic reply used"

    def self.with_slot(**options, &block)
      new(**options).call(&block)
    end

    # call_site names the caller ("mia_intent", "mia_narrator", ...) so denied
    # admissions, and the canned replies they cause, can be counted per path.
    def initialize(call_site: "unspecified", provider: PROVIDER, limit: configured_limit, wait_ms: configured_wait_ms, connection_pool: ActiveRecord::Base.connection_pool)
      @call_site = call_site.to_s
      @provider = provider
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @wait_ms = wait_ms.to_i.clamp(0, MAX_WAIT_MS)
      @connection_pool = connection_pool
    end

    def call
      started_at = monotonic_time
      deadline = started_at + (wait_ms / 1000.0)

      loop do
        connection_pool.with_connection do |connection|
          next if wait_ms.positive? && monotonic_time >= deadline

          slot = acquire(connection)
          if slot && (wait_ms.zero? || monotonic_time < deadline)
            instrument(admitted: true, waited_ms: elapsed_ms(started_at))
            begin
              return yield
            ensure
              release(connection, slot)
            end
          elsif slot
            release(connection, slot)
          end
        end

        remaining = deadline - monotonic_time
        break if remaining <= 0

        sleep([ POLL_INTERVAL_SECONDS, remaining ].min)
      end

      waited_ms = elapsed_ms(started_at)
      instrument(admitted: false, waited_ms: waited_ms)
      report_denied(reason: "capacity_full", waited_ms: waited_ms)
      nil
    rescue ActiveRecord::ActiveRecordError => e
      report_denied(reason: "admission_error", waited_ms: started_at ? elapsed_ms(started_at) : nil, error_class: e.class.name)
      nil
    end

    private

    attr_reader :call_site, :provider, :limit, :wait_ms, :connection_pool

    # Structured log + Sentry warning so deterministic fallbacks are visible.
    # Never include participant content: only the call site, reason, and timing.
    def report_denied(reason:, waited_ms:, error_class: nil)
      details = { call_site: call_site, reason: reason, provider: provider, limit: limit, waited_ms: waited_ms, error_class: error_class }.compact
      Rails.logger.warn({ event: DENIED_EVENT }.merge(details).to_json)
      return unless defined?(Sentry)

      Sentry.capture_message(
        DENIED_MESSAGE,
        level: :warning,
        tags: { mia_call_site: call_site, mia_admission_reason: reason },
        extra: details,
        fingerprint: [ DENIED_EVENT, call_site, reason ]
      )
    rescue StandardError => e
      Rails.logger.warn("[HouseholdFinance::MiaProviderAdmission] denied-admission report failed: #{e.class}")
    end

    def acquire(connection)
      (1..limit).find do |slot|
        ActiveModel::Type::Boolean.new.cast(
          connection.select_value("SELECT pg_try_advisory_lock(#{provider_key}, #{slot})")
        )
      end
    end

    def release(connection, slot)
      connection.select_value("SELECT pg_advisory_unlock(#{provider_key}, #{slot})")
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("[HouseholdFinance::MiaProviderAdmission] provider slot release failed: #{e.class}: #{e.message}")
    end

    def provider_key
      @provider_key ||= Digest::SHA256.digest(provider).unpack1("l>")
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def elapsed_ms(started_at)
      ((monotonic_time - started_at) * 1000).round
    end

    def instrument(admitted:, waited_ms:)
      ActiveSupport::Notifications.instrument(
        "mia.provider_admission",
        provider: provider,
        call_site: call_site,
        admitted: admitted,
        limit: limit,
        waited_ms: waited_ms
      )
    end

    def self.configured_limit
      ENV.fetch("MIA_PROVIDER_MAX_CONCURRENCY", DEFAULT_LIMIT).to_i
    end

    def configured_limit
      self.class.configured_limit
    end

    def self.configured_wait_ms
      ENV.fetch("MIA_PROVIDER_ADMISSION_WAIT_MS", DEFAULT_WAIT_MS).to_i
    end

    def configured_wait_ms
      self.class.configured_wait_ms
    end
  end
end
