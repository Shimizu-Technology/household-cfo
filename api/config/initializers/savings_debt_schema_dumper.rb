module SavingsDebtSchemaDumper
  private

  def header(stream)
    super
    dump_debt_functions(stream, %w[savings_debt_terms_valid(jsonb)])
  end

  def trailer(stream)
    dump_debt_functions(stream, %w[savings_debt_scope_guard() savings_debt_household_link_guard()])
    super
  end

  def dump_debt_functions(stream, signatures)
    signatures.each do |signature|
      function = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure(#{@connection.quote(signature)}))")
      next if function.blank?
      stream.puts "  execute <<~'SQL'\n#{function.lines.map { |line| "    #{line}" }.join}  SQL"
      @connection.select_values("SELECT pg_get_triggerdef(oid) || ';' FROM pg_trigger WHERE tgfoid = to_regprocedure(#{@connection.quote(signature)}) AND NOT tgisinternal ORDER BY tgname").each do |definition|
        stream.puts "  execute <<~'SQL'\n    #{definition}\n  SQL"
      end
    end
  end
end
ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(SavingsDebtSchemaDumper)
end
