Dir[File.join(__dir__, "scorecard", "*.rb")].sort.each { |path| require path }
