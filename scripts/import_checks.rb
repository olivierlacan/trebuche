#!/usr/bin/env ruby
# frozen_string_literal: true

# Copies the CSV rows from a "Checked in person" issue into the data file they belong to:
#   - street map reports (corner_id,...)        -> data/field-checks.csv
#   - citywide reports (intersection_id,...)    -> data/citywide-checks.csv
#
# The issue body is untrusted text, so every row is checked against what the pages
# write, column by column, and anything else is refused. Rows already in the file are
# skipped. Prints a short Markdown summary; exits 1 when nothing could be imported.
#
#   ruby scripts/import_checks.rb issue-body.md
#   ruby scripts/import_checks.rb --event "$GITHUB_EVENT_PATH"   (in the Action)
#
# Standard library only.

require "csv"
require "date"
require "json"

ROOT = File.expand_path("..", __dir__)

ISSUES = %w[diagonal old_style damaged lip].freeze
DATE = /\A20\d\d-[01]\d-[0-3]\d\z/
FEET = /\A\d{1,6}\z/
PAD = ->(v) { ["", "yes", "no"].include?(v) }
LIST = ->(v) { v.empty? || v.split("+").all? { ISSUES.include?(_1) } }
NOTES = ->(v) { v.length <= 200 && !v.match?(/[\r\n<>]/) }
OPT_FEET = ->(v) { v.empty? || v.match?(FEET) }

KINDS = {
  "field-checks.csv" => {
    header: %w[corner_id date_checked ramps_for yellow_pad ramp_issues notes distance_ft accuracy_ft],
    rules: {
      "corner_id" => ->(v) { v.match?(/\A[a-z][a-z0-9]*-\d+[A-Z]?-(NE|NW|SE|SW)\z/) },
      "date_checked" => ->(v) { v.match?(DATE) },
      "ramps_for" => ->(v) { %w[none main cross main+cross].include?(v) },
      "yellow_pad" => PAD, "ramp_issues" => LIST, "notes" => NOTES,
      "distance_ft" => OPT_FEET, "accuracy_ft" => OPT_FEET,
    },
  },
  "citywide-checks.csv" => {
    header: %w[intersection_id intersection lat lon corner date_checked ramps_for yellow_pad ramp_issues notes distance_ft accuracy_ft],
    rules: {
      "intersection_id" => ->(v) { v.match?(/\A\d{1,9}\z/) },
      "intersection" => ->(v) { v.match?(/\A[A-Za-z0-9 .&'\/-]{3,80}\z/) },
      # Seattle, and only as precise as the published intersection points
      "lat" => ->(v) { v.match?(/\A47\.\d{1,6}\z/) && v.to_f.between?(47.48, 47.74) },
      "lon" => ->(v) { v.match?(/\A-122\.\d{1,6}\z/) && v.to_f.between?(-122.46, -122.22) },
      "corner" => ->(v) { %w[NE NW SE SW].include?(v) },
      "date_checked" => ->(v) { v.match?(DATE) },
      "ramps_for" => ->(v) { %w[none no_corner ew ns ew+ns].include?(v) },
      "yellow_pad" => PAD, "ramp_issues" => LIST, "notes" => NOTES,
      "distance_ft" => OPT_FEET, "accuracy_ft" => OPT_FEET,
    },
  },
}.freeze

# The CSV in the body: a header line the pages write, then rows up to a blank line or
# the end of a code fence. Works whether or not the rows are fenced.
def extract(body)
  lines = body.gsub("\r\n", "\n").lines(chomp: true)
  KINDS.filter_map do |file, kind|
    start = lines.index { _1.strip == kind[:header].join(",") }
    next unless start

    rows = lines[(start + 1)..].take_while { !_1.strip.empty? && !_1.strip.start_with?("```") }
    [file, kind, rows.join("\n")]
  end
end

def valid_rows(kind, text)
  good, bad = [], []
  CSV.parse(text).each do |cells|
    row = kind[:header].zip(cells.map { _1.to_s.strip }).to_h
    ok = cells.size == kind[:header].size && kind[:rules].all? { |col, rule| rule.(row[col].to_s) } &&
         Date.parse(row["date_checked"]) <= Date.today + 1
    (ok ? good : bad) << row
  rescue Date::Error
    bad << row
  end
  [good, bad]
rescue CSV::MalformedCSVError
  [[], [:malformed]]
end

def main
  body = if ARGV[0] == "--event"
           JSON.parse(File.read(ARGV[1])).dig("issue", "body").to_s
         else
           File.read(ARGV[0])
         end
  found = extract(body)
  if found.empty?
    puts "No report rows found in the issue (no header line from the map or the report page)."
    exit 1
  end

  added = 0
  found.each do |file, kind, text|
    path = File.join(ROOT, "data", file)
    existing = File.exist?(path) ? CSV.read(path, headers: true).map { _1.to_h.transform_values(&:to_s) } : []
    good, bad = valid_rows(kind, text)
    fresh = good.uniq.reject { |r| existing.any? { _1 == r } }
    File.write(path, "#{kind[:header].join(",")}\n") unless File.exist?(path)
    CSV.open(path, "a", row_sep: "\n") { |csv| fresh.each { |r| csv << kind[:header].map { r[_1].empty? ? nil : r[_1] } } }
    added += fresh.size
    puts "- `data/#{file}`: #{fresh.size} row#{"s" unless fresh.size == 1} added" +
         (good.size > fresh.size ? ", #{good.size - fresh.size} already there" : "") +
         (bad.empty? ? "" : ", #{bad.size} refused (not in the format the pages write)")
  end
  exit 1 if added.zero?
end

main if $PROGRAM_NAME == __FILE__
