module SavingsDailySchemaDumper
  private

  def trailer(stream)
    %w[savings_daily_version_guard savings_daily_head_guard savings_daily_reflection_guard savings_daily_draft_guard].each do |name|
      function = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure('#{name}()'))")
      next if function.blank?

      stream.puts "  execute <<~'SQL'\n#{function.lines.map { |line| "    #{line}" }.join}  SQL"
      @connection.select_values("SELECT pg_get_triggerdef(oid) || ';' FROM pg_trigger WHERE tgfoid = to_regprocedure('#{name}()') AND NOT tgisinternal ORDER BY tgname").each do |definition|
        stream.puts "  execute <<~'SQL'\n    #{definition}\n  SQL"
      end
    end
    super
  end
end

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(SavingsDailySchemaDumper)
end
