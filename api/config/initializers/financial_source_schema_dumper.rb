# frozen_string_literal: true

# Keep append-only guarantees when loading schema.rb into a fresh database.
module FinancialSourceSchemaDumper
  private

  def trailer(stream)
    if @connection.table_exists?("financial_source_events")
      function = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure('source_accounting_facts_immutable()'))")
      if function.present?
        stream.puts "  execute <<~SQL\n#{function.lines.map { |line| "    #{line}" }.join}  SQL"
        %w[financial_extraction_revisions financial_source_accounts financial_source_events].each do |table|
          trigger = "#{table}_immutable"
          definition = @connection.select_value("SELECT pg_get_triggerdef(oid) || ';' FROM pg_trigger WHERE tgname = #{@connection.quote(trigger)} AND NOT tgisinternal")
          stream.puts "  execute <<~SQL\n    DROP TRIGGER IF EXISTS #{trigger} ON #{table};\n    #{definition}\n  SQL" if definition.present?
        end
      end
    end
    super
  end
end

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"
  dumper = ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper
  dumper.prepend(FinancialSourceSchemaDumper) unless dumper < FinancialSourceSchemaDumper
end
