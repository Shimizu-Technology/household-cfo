# Exact structured fixtures for pre-existing conversation assertions. The old
# interpretation rules are deliberately absent from the app and test runtime.
module ParticipantReaderTestSupport
  def self.included(base)
    base.setup do
      @participant_reader_original = HouseholdFinance::ParticipantMessageReader.method(:call)
      @participant_reader_fixtures = JSON.parse(File.read(Rails.root.join("test/fixtures/files/participant_reader_legacy.json")))
      original = @participant_reader_original
      fixtures = @participant_reader_fixtures
      HouseholdFinance::ParticipantMessageReader.define_singleton_method(:call) do |**options|
        data = fixtures[options[:message].to_s]
        next original.call(**options.merge(api_key: "")) unless data

        # A fixture answers only the question its case establishes. This keeps
        # a literal reused in a different stage from becoming a guessed answer.
        copy = data.deep_dup
        field = HouseholdFinance::ParticipantMessageReader::SETUP_FIELDS[copy.dig("setup_answer", "field")]
        target = copy["correction"] ? options[:pending_field] : options[:setup_field]
        copy["setup_answer"] = { "field" => "none", "value" => "" } if field && target != field
        reader = new(**options.merge(api_key: ""))
        result = begin
          reader.send(:validate, copy)
        rescue ArgumentError
          reader.send(:fallback)
        end
        HouseholdFinance::ParticipantMessageReader::Current.message = options[:message].to_s
        HouseholdFinance::ParticipantMessageReader::Current.reading = result
        result
      end
    end
    base.teardown do
      HouseholdFinance::ParticipantMessageReader::Current.reset
      HouseholdFinance::ParticipantMessageReader.define_singleton_method(:call, @participant_reader_original) if @participant_reader_original
    end
  end
  def with_participant_reader_response(data)
    klass = HouseholdFinance::ParticipantMessageReader
    original = klass.method(:call)
    klass.define_singleton_method(:call) do |**options|
      new(**options.merge(transport: ->(_payload) { JSON.generate(data) })).call
    end
    yield
  ensure
    klass.define_singleton_method(:call, original)
  end
end
