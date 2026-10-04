module SavingsChallengeSchemaDumper
  private

  def trailer(stream)
    if @connection.table_exists?("savings_enrollments")
      %w[savings_prevent_mutation() savings_scope_guard() savings_identity_guard() savings_draft_guard() savings_approval_head_guard() savings_enrollment_release_guard()].each do |signature|
        definition = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure(#{@connection.quote(signature)}))")
        dump_savings_sql(stream, definition) if definition.present?
      end
      triggers = @connection.select_rows(<<~SQL)
        SELECT t.tgname, c.relname, pg_get_triggerdef(t.oid) || ';'
        FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname IN ('savings_enrollments','savings_entries','savings_entry_versions','savings_plan_versions','savings_zero_attestations','savings_entry_drafts','savings_plan_drafts')
          AND NOT t.tgisinternal ORDER BY t.tgname
      SQL
      triggers.each do |name, table, definition|
        dump_savings_sql(stream, "DROP TRIGGER IF EXISTS #{name} ON #{table};\n#{definition}")
      end
    end
    super
  end

  def dump_savings_sql(stream, definition)
    stream.puts "  execute <<~'SQL'"
    definition.each_line { |line| stream.puts "    #{line.rstrip}" }
    stream.puts "  SQL"
  end
end

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"
  dumper = ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper
  dumper.prepend(SavingsChallengeSchemaDumper) unless dumper < SavingsChallengeSchemaDumper
end
