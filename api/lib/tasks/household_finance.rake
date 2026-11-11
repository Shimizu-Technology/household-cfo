namespace :household_finance do
  desc "Split chat-setup bill totals into one budget row per bill where the applied breakdown still matches. DRY_RUN=1 to preview; safe to run twice."
  task split_setup_bills: :environment do
    logger = ActiveSupport::Logger.new($stdout)
    results = HouseholdFinance::SetupBillBackfill.call(dry_run: ENV["DRY_RUN"] == "1", logger: logger)
    counts = results.group_by(&:action).transform_values(&:count)
    puts "[SetupBillBackfill] #{ENV['DRY_RUN'] == '1' ? 'dry run' : 'done'}: #{counts.presence || 'nothing to change'}"
  end
end
