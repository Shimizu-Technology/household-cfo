module SourceReviewSchemaDumper
  private

  def trailer(stream)
    %w[source_review_facts_immutable source_review_heads_scope_immutable].each do |name|
      function = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure('#{name}()'))")
      if function.present?
        stream.puts "  execute <<~SQL\n#{function.lines.map { |line| "    #{line}" }.join}  SQL"
        @connection.select_values("SELECT pg_get_triggerdef(oid) || ';' FROM pg_trigger WHERE tgfoid = to_regprocedure('#{name}()') AND NOT tgisinternal ORDER BY tgname").each do |definition|
          stream.puts "  execute <<~SQL\n    #{definition}\n  SQL"
        end
      end
    end
    super
  end
end

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(SourceReviewSchemaDumper)
end
