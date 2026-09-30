# frozen_string_literal: true

require "csv"
require "roo"
require "roo-xls"

module FinancialDocuments
  class SpreadsheetSummarizer
    MAX_SHEETS = 50
    MAX_ROWS_PER_SHEET = HouseholdFinance::DocumentTransactionDraftPersister::MAX_DRAFTS + 1
    MAX_COLUMNS = 20
    MAX_SCANNED_CELLS = 250_000
    MAX_CELL_LENGTH = 120
    MAX_SHEET_NAME_LENGTH = 80

    def initialize(file_path:, filename:)
      @file_path = file_path
      @filename = filename
    end

    def call
      spreadsheet = open_spreadsheet
      sheet_names = spreadsheet.sheets
      @scanned_cells = 0
      @scan_incomplete = false
      sheet_limit_exceeded = sheet_names.length > MAX_SHEETS
      {
        filename: filename,
        sheet_count: sheet_names.length,
        sheet_limit_exceeded: sheet_limit_exceeded,
        sheets: sheet_names.first(MAX_SHEETS).map do |sheet_name|
          spreadsheet.default_sheet = sheet_name
          summarize_sheet(spreadsheet, sheet_name)
        end.compact,
        scan_incomplete: @scan_incomplete || sheet_limit_exceeded
      }
    end

    private

    attr_reader :file_path, :filename

    def open_spreadsheet
      case File.extname(filename.to_s).downcase
      when ".xlsx"
        Roo::Excelx.new(file_path)
      when ".xls"
        Roo::Excel.new(file_path)
      when ".csv"
        Roo::CSV.new(file_path)
      else
        Roo::Spreadsheet.open(file_path)
      end
    end

    def summarize_sheet(spreadsheet, sheet_name)
      last_row = spreadsheet.last_row.to_i
      last_column = [ spreadsheet.last_column.to_i, MAX_COLUMNS ].min
      return nil if last_row.zero? || last_column.zero?

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
        row_count: last_row,
        sampled_row_count: rows.length,
        rows_truncated: rows_truncated,
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
