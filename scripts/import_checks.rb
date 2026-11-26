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
YES = ->(v) { ["", "yes"].include?(v) }

KINDS = {
  "field-checks.csv" => {
    header: %w[corner_id date_checked ramps_for yellow_pad ramp_issues notes distance_ft accuracy_ft newly_built],
    rules: {
      "corner_id" => ->(v) { v.match?(/\A[a-z][a-z0-9]*-\d+[A-Z]?-(NE|NW|SE|SW)\z/) },
      "date_checked" => ->(v) { v.match?(DATE) },
      "ramps_for" => ->(v) { %w[none main cross main+cross].include?(v) },
      "yellow_pad" => PAD, "ramp_issues" => LIST, "notes" => NOTES,
      "distance_ft" => OPT_FEET, "accuracy_ft" => OPT_FEET, "newly_built" => YES,
    },
  },
  "citywide-checks.csv" => {
    header: %w[intersection_id intersection lat lon corner date_checked ramps_for yellow_pad ramp_issues notes distance_ft accuracy_ft newly_built],
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
      "distance_ft" => OPT_FEET, "accuracy_ft" => OPT_FEET, "newly_built" => YES,
    },
  },
}.freeze

# Columns added since the pages first wrote reports. A report written before one was added
# (an issue opened from an older copy of a page) has the header without it, and its rows
# get the column blank.
ADDED = %w[newly_built].freeze

# The CSV in the body: a header line the pages write, then rows up to a blank line or
# the end of a code fence. Works whether or not the rows are fenced. Returns the header
# the body used, so older rows can be filled out.
def extract(body)
  lines = body.gsub("\r\n", "\n").lines(chomp: true)
  KINDS.filter_map do |file, kind|
    headers = (0..ADDED.size).map { |n| kind[:header][0, kind[:header].size - n] }
    start, used = lines.each_with_index.filter_map { |l, i| (h = headers.find { l.strip == _1.join(",") }) && [i, h] }.first
    next unless start

    rows = lines[(start + 1)..].take_while { !_1.strip.empty? && !_1.strip.start_with?("```") }
    [file, kind, rows.join("\n"), used]
  end
end

def valid_rows(kind, text, used = kind[:header])
  good, bad = [], []
  CSV.parse(text).each do |cells|
    row = kind[:header].zip(cells.map { _1.to_s.strip } + [""] * (kind[:header].size - used.size)).to_h
    ok = cells.size == used.size && kind[:rules].all? { |col, rule| rule.(row[col].to_s) } &&
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
  found.each do |file, kind, text, used|
    path = File.join(ROOT, "data", file)
    existing = File.exist?(path) ? CSV.read(path, headers: true).map { |r| kind[:header].to_h { |h| [h, r[h].to_s] } } : []
    good, bad = valid_rows(kind, text, used)
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
