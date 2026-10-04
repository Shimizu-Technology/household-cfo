module ChallengeChatSchemaDumper
  private

  def trailer(stream)
    signature = "challenge_chat_scope_guard()"
    function = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure(#{@connection.quote(signature)}))")
    if function.present?
      stream.puts "  execute <<~'SQL'\n#{function.lines.map { |line| "    #{line}" }.join}  SQL"
      @connection.select_values("SELECT pg_get_triggerdef(oid) || ';' FROM pg_trigger WHERE tgfoid = to_regprocedure(#{@connection.quote(signature)}) AND NOT tgisinternal ORDER BY tgname").each do |definition|
        stream.puts "  execute <<~'SQL'\n    #{definition}\n  SQL"
      end
    end
    super
  end
end

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(ChallengeChatSchemaDumper)
end
