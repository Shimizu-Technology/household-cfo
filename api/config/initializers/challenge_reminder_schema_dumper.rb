module ChallengeReminderSchemaDumper
  private
  def trailer(stream)
    function = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure('challenge_reminder_identity_guard()'))")
    if function.present?
      stream.puts "  execute <<~SQL\n#{function.lines.map { |line| "    #{line}" }.join}  SQL"
      @connection.select_values("SELECT pg_get_triggerdef(oid) || ';' FROM pg_trigger WHERE tgfoid = to_regprocedure('challenge_reminder_identity_guard()') AND NOT tgisinternal ORDER BY tgname").each { |definition| stream.puts "  execute <<~SQL\n    #{definition}\n  SQL" }
    end
    super
  end
end
ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(ChallengeReminderSchemaDumper)
end
