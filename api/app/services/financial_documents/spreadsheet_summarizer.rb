# frozen_string_literal: true

require "csv"
require "roo"

module FinancialDocuments
  class SpreadsheetSummarizer
    MAX_SHEETS = 5
    MAX_ROWS_PER_SHEET = 80
    MAX_COLUMNS = 20
    MAX_CELL_LENGTH = 120

    def initialize(file_path:, filename:)
      @file_path = file_path
      @filename = filename
    end

    def call
      spreadsheet = open_spreadsheet
      {
        filename: filename,
        sheets: spreadsheet.sheets.first(MAX_SHEETS).map do |sheet_name|
          spreadsheet.default_sheet = sheet_name
          summarize_sheet(spreadsheet, sheet_name)
        end.compact
      }
    end

    private

    attr_reader :file_path, :filename

    def open_spreadsheet
      case File.extname(filename.to_s).downcase
      when ".xlsx"
        Roo::Excelx.new(file_path)
      when ".csv"
        Roo::CSV.new(file_path)
      when ".xls"
        raise ArgumentError, "Legacy .xls spreadsheets are not supported. Save as .xlsx or CSV and upload again."
      else
        Roo::Spreadsheet.open(file_path)
      end
    end

    def summarize_sheet(spreadsheet, sheet_name)
      last_row = spreadsheet.last_row.to_i
      last_column = [ spreadsheet.last_column.to_i, MAX_COLUMNS ].min
      return nil if last_row.zero? || last_column.zero?

      rows = []
      (1..[ last_row, MAX_ROWS_PER_SHEET ].min).each do |row_number|
        values = (1..last_column).map { |column_number| clean_cell(spreadsheet.cell(row_number, column_number)) }
        next if values.all?(&:blank?)

        rows << { row: row_number, values: values }
      end

      return nil if rows.empty?

      {
        name: sheet_name,
        row_count: last_row,
        sampled_row_count: rows.length,
        columns_seen: last_column,
        rows: rows
      }
    end

    def clean_cell(value)
      text = value.to_s.unicode_normalize(:nfkc).gsub(/[[:cntrl:]]/, " ").squish
      text.truncate(MAX_CELL_LENGTH, omission: "…")
    end
  end
end
