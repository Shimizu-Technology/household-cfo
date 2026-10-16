# frozen_string_literal: true

require "csv"
require "fileutils"
require "roo"
require "roo-xls"
require "tempfile"
require "zip"

module FinancialDocuments
  class SpreadsheetSummarizer
    MAX_SHEETS = 50
    MAX_ROWS_PER_SHEET = HouseholdFinance::DocumentTransactionDraftPersister::MAX_DRAFTS + 1
    MAX_COLUMNS = 200
    MAX_SCANNED_CELLS = 250_000
    MAX_CELL_LENGTH = 120
    MAX_SHEET_NAME_LENGTH = 80
    WORKSHEET_ENTRY = %r{\Axl/worksheets/[^/]+\.xml\z}
    EMPTY_CACHED_VALUE = %r{<v\s*/>|<v>\s*</v>}
    UNCALCULATED_MESSAGE = "This workbook has formulas without saved results, so we couldn't read it. Open it in Excel or Google Sheets, save it again (or export it as CSV), then upload the new copy."

    # A participant-safe reason the workbook cannot be read.
    class Unreadable < StandardError; end

    def self.uncalculated_formula_warning(count)
      "#{count} formula #{count == 1 ? 'cell' : 'cells'} (such as a total) had no saved result, so #{count == 1 ? 'it was' : 'they were'} left blank. If you need #{count == 1 ? 'that value' : 'those values'}, open the file in Excel or Google Sheets, save it, and upload it again."
    end

    def initialize(file_path:, filename:)
      @file_path = file_path
      @filename = filename
    end

    def call
      summarize(open_spreadsheet)
    rescue ArgumentError, TypeError => error
      raise unless xlsx?

      summarize_without_uncalculated_formulas(error)
    end

    private

    attr_reader :file_path, :filename

    def xlsx?
      File.extname(filename.to_s).downcase == ".xlsx"
    end

    # Roo cannot load a sheet containing a formula whose cached result is
    # empty (a file written by a script, never opened in Excel). Read a copy
    # with those empty results removed: the formula cells read as blank and
    # the participant is told which values are missing.
    def summarize_without_uncalculated_formulas(original_error)
      patched = Tempfile.new([ "financial_document_formulas", ".xlsx" ])
      patched.close
      count = strip_empty_cached_values(patched.path)
      raise original_error if count.zero?

      begin
        summarize(Roo::Excelx.new(patched.path)).merge(uncalculated_formula_cells: count)
      rescue ArgumentError, TypeError
        raise Unreadable, UNCALCULATED_MESSAGE
      end
    ensure
      patched&.close!
    end

    def strip_empty_cached_values(path)
      FileUtils.cp(file_path, path)
      count = 0
      Zip::File.open(path) do |zip|
        zip.entries.select { |entry| entry.name.match?(WORKSHEET_ENTRY) }.each do |entry|
          xml = SourceSafety.read_ooxml_xml(zip, entry.name)
          next unless xml

          stripped = xml.gsub(EMPTY_CACHED_VALUE) { count += 1; "" }
          zip.get_output_stream(entry.name) { |io| io.write(stripped) } if stripped != xml
        end
        zip.commit
      end
      count
    rescue Zip::Error
      raise Unreadable, UNCALCULATED_MESSAGE
    end

    def summarize(spreadsheet)
      sheet_names = spreadsheet.sheets
      @scanned_cells = 0
      @scan_incomplete = false
      @column_limit_exceeded = false
      sheet_limit_exceeded = sheet_names.length > MAX_SHEETS
      {
        filename: filename,
        sheet_count: sheet_names.length,
        sheet_limit_exceeded: sheet_limit_exceeded,
        sheets: sheet_names.first(MAX_SHEETS).each_with_index.map do |sheet_name, sheet_index|
          spreadsheet.default_sheet = sheet_name
          summarize_sheet(spreadsheet, sheet_name, sheet_index: sheet_index)
        end.compact,
        column_limit_exceeded: @column_limit_exceeded,
        scan_incomplete: @scan_incomplete || sheet_limit_exceeded
      }
    end

    def open_spreadsheet
      case File.extname(filename.to_s).downcase
      when ".xlsx"
        SourceSafety.check_ooxml!(file_path)
        Roo::Excelx.new(file_path)
      when ".xls"
        Roo::Excel.new(file_path)
      when ".csv"
        Roo::CSV.new(file_path)
      else
        Roo::Spreadsheet.open(file_path)
      end
    end

    def summarize_sheet(spreadsheet, sheet_name, sheet_index: 0)
      last_row = spreadsheet.last_row.to_i
      actual_last_column = spreadsheet.last_column.to_i
      return nil if last_row.zero? || actual_last_column.zero?
      if actual_last_column > MAX_COLUMNS
        @column_limit_exceeded = true
        return {
          name: clean_sheet_name(sheet_name),
          sheet_index: sheet_index,
          row_count: last_row,
          sampled_row_count: 0,
          rows_truncated: false,
          column_count: actual_last_column,
          columns_seen: 0,
          rows: []
        }
      end
      last_column = actual_last_column

      rows = []
      rows_truncated = false
      (1..last_row).each do |row_number|
        if scanned_cells + last_column > MAX_SCANNED_CELLS
          @scan_incomplete = true
          break
        end

        values = (1..last_column).map { |column_number| clean_cell(spreadsheet.cell(row_number, column_number)) }
        @scanned_cells = scanned_cells + last_column
        next if values.all?(&:blank?)
        if rows.length >= MAX_ROWS_PER_SHEET
          rows_truncated = true
          break
        end

        cell_types = if spreadsheet.respond_to?(:celltype)
          (1..last_column).map { |column_number| spreadsheet.celltype(row_number, column_number) }
        else
          []
        end
        cell_formats = if spreadsheet.respond_to?(:excelx_format)
          (1..last_column).map { |column_number| spreadsheet.excelx_format(row_number, column_number) }
        else
          []
        end
        rows << { row: row_number, values: values, cell_types: cell_types, cell_formats: cell_formats }
      end

      return nil if rows.empty?

      {
        name: clean_sheet_name(sheet_name),
        sheet_index: sheet_index,
        row_count: last_row,
        sampled_row_count: rows.length,
        rows_truncated: rows_truncated,
        column_count: actual_last_column,
        columns_seen: last_column,
        rows: rows
      }
    end

    def scanned_cells
      @scanned_cells ||= 0
    end

    def clean_sheet_name(value)
      clean_text(value, max_length: MAX_SHEET_NAME_LENGTH).presence || "Sheet"
    end

    def clean_cell(value)
      value = value.to_i if value.is_a?(Float) && value.finite? && value == value.to_i
      clean_text(value, max_length: MAX_CELL_LENGTH)
    end

    def clean_text(value, max_length:)
      value.to_s
        .unicode_normalize(:nfkc)
        .gsub(/[[:cntrl:]]/, " ")
        .gsub(/[<>`]/, "")
        .squish
        .truncate(max_length, omission: "…")
    end
  end
end
