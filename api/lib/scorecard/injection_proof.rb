require "fileutils"

module Scorecard
  # Deliberately corrupt copies of fictional recordings, never the committed
  # originals. Run this before accepting a baseline migration.
  class InjectionProof
    PATHS = %w[apple-2026-01.pdf bog-2026-11-phone-1.png bog-2026-11-phone-2.png bog-2026-11-phone-3.png].freeze

    def self.call
      Dir.mktmpdir("scorecard-injections-") do |directory|
        root = Pathname.new(directory)
        root.join("recorded_responses").mkpath
        FileUtils.cp(Runner::TALUN.join("manifest.json"), root.join("manifest.json"))
        PATHS.each do |name|
          FileUtils.cp(Runner::TALUN.join(name), root.join(name))
          FileUtils.cp(Runner::TALUN.join("recorded_responses", "#{name}.json"), root.join("recorded_responses", "#{name}.json"))
        end
        run = -> { Runner.new(family_dir: root, private_mode: true, document_paths: PATHS).call }
        baseline = run.call
        path = root.join("recorded_responses/apple-2026-01.pdf.json")
        original = path.read
        results = %w[type date].to_h do |field|
          recording = JSON.parse(original)
          changed = 0
          recording.fetch("responses").each do |section|
            content = section.fetch("response").fetch("data").fetch("content").strip.sub(/\A```json\s*/i, "").sub(/\s*```\z/, "")
            data = JSON.parse(content)
            data.fetch("source_accounting").fetch("events").each do |event|
              next unless event["event_type"] == "purchase" && changed < 2
              if field == "type"
                event["event_type"] = "transfer"
              else
                event["posted_on"] = (Date.iso8601(event.fetch("posted_on")) + 1.day).iso8601
              end
              changed += 1
            end
            section.fetch("response").fetch("data")["content"] = JSON.generate(data)
          end
          raise "Injection must change exactly two purchases" unless changed == 2
          path.write(JSON.generate(recording))
          failures = Ratchet.regressions(run.call, baseline)
          raise "#{field} injection escaped the ratchet" if failures.empty?
          path.write(original)
          [ field, failures ]
        end
        plan = FinancialDocuments::SourceReview::ParticipantPlan
        classify = plan.instance_method(:classify)
        begin
          plan.define_method(:classify) do |*args, **options|
            kind = classify.bind_call(self, *args, **options)
            kind == :duplicate ? nil : kind
          end
          # With the flag off, the approval guard may refuse the overlapping rows before
          # anything is counted. That refusal is a catch, not an escape.
          failures = begin
            Ratchet.regressions(run.call, baseline)
          rescue ArgumentError, FinancialDocuments::SourceReview::Domain::StaleReview => error
            # The approver reports the guard's refusal as a stale review; its cause is the overlap.
            refusal = [ error, error.cause ].compact.find { |raised| raised.message.start_with?("These rows may overlap.") }
            raise unless refusal
            [ "approval refused overlapping rows: #{refusal.message}" ]
          end
          raise "Duplicate flag injection escaped the ratchet" if failures.empty?
          results["duplicate_flag_off"] = failures
        ensure
          plan.define_method(:classify, classify)
          plan.send(:private, :classify)
        end
        results
      end
    end
  end
end
