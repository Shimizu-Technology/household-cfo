namespace :scorecard do
  desc "Replay the Talun year offline; PRIVATE=1 accepts external FAMILY_DIR and ANSWER_KEY"
  task run: :environment do
    require Rails.root.join("lib/scorecard")
    private_mode = ENV["PRIVATE"] == "1"
    options = if private_mode
      { family_dir: ENV.fetch("FAMILY_DIR"), answer_key: ENV.fetch("ANSWER_KEY"), private_mode: true }
    else
      raise ArgumentError, "Unknown family" unless ENV.fetch("FAMILY", "talun-year") == "talun-year"
      ENV["SAMPLE"] == "1" ? { document_paths: Scorecard::Runner::FAST_PATHS } : {}
    end
    report = Scorecard::Runner.new(**options).call
    puts Scorecard::Report.table(report)
    puts JSON.pretty_generate(report)
    if !private_mode && ENV["RATCHET"] == "1"
      baseline = JSON.parse(Scorecard::Runner::TALUN.join(ENV["SAMPLE"] == "1" ? "baseline-fast.json" : "baseline.json").read)
      failures = Scorecard::Ratchet.regressions(report, baseline)
      abort "Scorecard regressions: #{failures.join(', ')}" if failures.any?
    end
  rescue StandardError
    # Private failures must not emit paths, descriptors or source excerpts.
    raise unless private_mode
    abort "Private scorecard could not finish. Check the external answer key, recordings, and test database."
  end

  desc "Prove purchase-to-transfer, shifted-date and disabled-duplicate regressions fail"
  task prove_injections: :environment do
    require Rails.root.join("lib/scorecard")
    puts JSON.pretty_generate(Scorecard::InjectionProof.call)
  end

  desc "Record missing Talun provider responses (explicit live-model opt-in)"
  task record: :environment do
    require Rails.root.join("lib/scorecard")
    raise "Use RAILS_ENV=test and RECORD=1" unless Rails.env.test? && ENV["RECORD"] == "1"
    require "dotenv"
    key = Dotenv.parse(ENV.fetch("RECORDING_ENV_FILE")).fetch("OPENROUTER_API_KEY")
    Scorecard::Recorder.call(root: Scorecard::Runner::TALUN, api_key: key, refresh: ENV["RERECORD"] == "1")
  end
end
