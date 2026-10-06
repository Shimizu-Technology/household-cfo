# PostgreSQL triggers are part of the tenant boundary on fresh schema loads too.
module EnterpriseSchemaDumper
  private

  def trailer(stream)
    if @connection.table_exists?("enterprise_cohort_grants")
      {
        "enterprise_mapping_boundary" => [ "enterprise_group_mappings", "enforce_enterprise_mapping_boundary" ],
        "enterprise_directory_boundary" => [ "enterprise_directory_users", "enforce_enterprise_directory_boundary" ],
        "enterprise_grant_boundary" => [ "enterprise_cohort_grants", "enforce_enterprise_grant_boundary" ]
      }.each do |trigger, (table, function)|
        definition = @connection.select_value("SELECT pg_get_functiondef(to_regprocedure('#{function}()'))")
        next unless definition
        trigger_definition = @connection.select_value("SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgname = '#{trigger}' AND tgrelid = '#{table}'::regclass")
        next unless trigger_definition
        stream.puts "  execute <<~SQL\n#{definition};\nDROP TRIGGER IF EXISTS #{trigger} ON #{table};\n#{trigger_definition};\n  SQL"
      end
    end
    super
  end
end

ActiveSupport.on_load(:active_record) do
  require "active_record/connection_adapters/postgresql/schema_dumper"
  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaDumper.prepend(EnterpriseSchemaDumper)
end
