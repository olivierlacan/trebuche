#!/usr/bin/env ruby
# frozen_string_literal: true

# Build a per-corner curb ramp inventory for Dayton Ave N (N 60th - N 85th St).
#
# Reads data/raw/* (from fetch.rb) and data/requests.csv, writes:
#   output/corners.csv      one row per intersection corner
#   output/corners.geojson  same, as points
#   output/map.html         Leaflet map (data embedded; open directly in a browser)
#
# Each corner can need up to two ramps: one for crossing Dayton ("main") and one
# for crossing the side street ("cross"). A corner with only one of the two is
# "partial" -- for a stroller that is still a dead end.
#
# Standard library only. Run from the repo root:  ruby scripts/build.rb

require "csv"
require "json"
require "set"
require "time"

ROOT = File.expand_path("..", __dir__)
RAW = File.join(ROOT, "data", "raw")
OUT = File.join(ROOT, "output")

MAIN_STREET = "Dayton Avenue North"
FIRST_ST = 60
LAST_ST = 85

MATCH_RADIUS_M = 30   # evidence farther than this from an intersection is ignored
CORNER_OFFSET_M = 9   # where to draw a corner marker, diagonally from the center
LEG_PROBE_M = 25      # a street node this far out along an axis means a leg exists
JOG_THRESHOLD_M = 10  # N and S approaches of Dayton offset by more than this = jog
APPROACH_M = 15       # how far up/down Dayton to sample its position

M_PER_DEG_LAT = 111_320.0
M_PER_DEG_LON = 111_320.0 * Math.cos(47.68 * Math::PI / 180)

OPPOSITE = { "N" => "S", "S" => "N", "E" => "W", "W" => "E" }.freeze
ROAD_TYPES = %w[residential tertiary secondary primary unclassified].to_set.freeze

def to_xy(lat, lon, lat0, lon0)
  [(lon - lon0) * M_PER_DEG_LON, (lat - lat0) * M_PER_DEG_LAT]
end

def from_xy(x, y, lat0, lon0)
  [lat0 + y / M_PER_DEG_LAT, lon0 + x / M_PER_DEG_LON]
end

def ordinal(n)
  suffix = (11..13).cover?(n % 100) ? "th" : { 1 => "st", 2 => "nd", 3 => "rd" }.fetch(n % 10, "th")
  "#{n}#{suffix}"
end

def ms_to_date(ms)
  ms ? Time.at(ms / 1000).utc.strftime("%F") : ""
end

def median(values)
  values.sort[values.size / 2]
end

def load(name)
  JSON.parse(File.read(File.join(RAW, name)))
end

def blank(s)
  s.to_s.strip
end

# ---------------------------------------------------------------------------
# Intersections (from OSM street geometry)
# ---------------------------------------------------------------------------

def load_osm
  els = load("osm.json")["elements"]
  # Keep the richest copy of each node (an element can appear more than once).
  nodes = els.select { _1["type"] == "node" }.group_by { _1["id"] }
             .transform_values { |copies| copies.max_by { _1.fetch("tags", {}).size } }
  ways = els.select { _1["type"] == "way" && _1.dig("tags", "highway") }
  [nodes, ways]
end

# Intersections along MAIN_STREET, found geometrically.
#
# Many Dayton intersections have neighborhood traffic circles where the named
# ways stop short of the center, so shared nodes can't be relied on. Dayton
# also jogs at N 64th and N 65th (the north and south halves of Dayton don't
# line up, so you turn briefly onto the side street to continue); each jog
# becomes two T-intersections.
def find_intersections(nodes, ways)
  main_segs = ways.select { _1.dig("tags", "name") == MAIN_STREET }.flat_map do |w|
    pts = w["nodes"].filter_map { |n| nodes[n] && [nodes[n]["lat"], nodes[n]["lon"]] }
    pts.each_cons(2).to_a
  end
  main_lon = median(main_segs.map { _1[0][1] })

  cross_pts = Hash.new { |h, k| h[k] = [] }
  ways.each do |w|
    m = /\ANorth (\d+)(?:st|nd|rd|th) Street\z/.match(w.dig("tags", "name").to_s)
    next unless m && ROAD_TYPES.include?(w["tags"]["highway"])

    num = m[1].to_i
    next unless (FIRST_ST..LAST_ST).cover?(num)

    cross_pts[num].concat(w["nodes"].filter_map { |n| nodes[n] && [nodes[n]["lat"], nodes[n]["lon"]] })
  end

  cross_pts.keys.sort.flat_map do |num|
    pts = cross_pts[num]
    near = pts.select { (_1[1] - main_lon).abs * M_PER_DEG_LON < 80 }
    next [] if near.empty?

    lat = median(near.map(&:first))

    # Longitude of Dayton APPROACH_M south (-1) or north (+1) of this street:
    # far enough to clear a traffic circle, short of the next block.
    approach = lambda do |sign|
      target = lat + sign * APPROACH_M / M_PER_DEG_LAT
      seg = main_segs.find do |(alat, _), (blat, _)|
        alat != blat && [alat, blat].min <= target && target <= [alat, blat].max
      end
      next nil unless seg

      (alat, alon), (blat, blon) = seg
      alon + (target - alat) / (blat - alat) * (blon - alon)
    end
    s_lon = approach.call(-1)
    n_lon = approach.call(1)

    centers =
      if s_lon && n_lon && (s_lon - n_lon).abs * M_PER_DEG_LON > JOG_THRESHOLD_M
        (wl, wd), (el, ed) = [[s_lon, "S"], [n_lon, "N"]].sort
        [[wl, "W", [wd]], [el, "E", [ed]]]
      else
        present = { "S" => s_lon, "N" => n_lon }.compact
        [[present.values.sum / present.size, "", present.keys]]
      end

    centers.map do |lon, suffix, main_legs|
      legs = main_legs.to_set
      pts.each do |plat, plon|
        x, y = to_xy(plat, plon, lat, lon)
        legs << (x.positive? ? "E" : "W") if y.abs < 10 && x.abs > LEG_PROBE_M
      end
      name = "N #{ordinal(num)} St"
      name += " (#{suffix == "W" ? "west" : "east"} side of jog)" unless suffix.empty?
      { id: "#{num}#{suffix}", cross_street: name, lat: lat, lon: lon,
        legs: %w[N E S W].select { legs.include?(_1) }.join }
    end
  end
end

# Four corners; for each, which crossings start there.
#
# Corner "NE":
#   main  crossing: across Dayton's N leg, to the NW corner
#   cross crossing: across the side street's E leg, to the SE corner
def corners_for(ix)
  %w[NE NW SE SW].map do |q|
    ns, ew = q.chars
    needs = []
    needs << "main" if ix[:legs].include?(ns)
    needs << "cross" if ix[:legs].include?(ew)
    lat, lon = from_xy(CORNER_OFFSET_M * (ew == "E" ? 1 : -1),
                       CORNER_OFFSET_M * (ns == "N" ? 1 : -1), ix[:lat], ix[:lon])
    {
      "corner_id" => "dayton-#{ix[:id]}-#{q}",
      "intersection_id" => ix[:id],
      "cross_street" => ix[:cross_street],
      "corner" => q,
      "corner_type" => needs.size == 2 ? "corner" : "T-intersection landing",
      "needs" => needs,
      "lat" => lat.round(6),
      "lon" => lon.round(6),
    }
  end
end

# Group [lat, lon, payload] by [intersection_id, quadrant].
def assign(points, intersections)
  points.each_with_object(Hash.new { |h, k| h[k] = [] }) do |(lat, lon, payload), acc|
    ix, x, y = intersections.map { |i| [i, *to_xy(lat, lon, i[:lat], i[:lon])] }
                            .min_by { |_, dx, dy| Math.hypot(dx, dy) }
    next unless ix && Math.hypot(x, y) < MATCH_RADIUS_M

    acc[[ix[:id], (y >= 0 ? "N" : "S") + (x >= 0 ? "E" : "W")]] << payload
  end
end

# present / partial / missing / unknown from per-crossing coverage.
#
# gaps_mean_missing: whether a needed crossing with no evidence at all counts
# as lacking a ramp. True for the SDOT inventory (surveyed corners list every
# ramp); false for OSM, where an unmapped kerb just means unmapped.
def coverage_verdict(needs, covered, any_ramp, any_missing, gaps_mean_missing: false)
  return "present" if !needs.empty? && needs.all? { covered.include?(_1) }
  return "partial" if any_ramp && (any_missing || (!covered.empty? && gaps_mean_missing))
  return "present" if any_ramp # ramp(s) present, direction unknown
  return "missing" if any_missing

  "unknown"
end

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

def built?(r) = %w[SINGLE SHARED].include?(blank(r["CATEGORY"]))

def open_work_orders
  load("city_work_orders.geojson")["features"].each_with_object(Hash.new { |h, k| h[k] = [] }) do |f, acc|
    a = f["properties"]
    next unless a["PROBLEMDESC"] == "Planned Construction" && !a["CLOSEDDT"] && a["CANCELLEDFLAG"] != "Y"

    acc[a["UNITID"]] << blank(a["GROUPPROJNAME"])
  end
end

def city_evidence(intersections, needs)
  wo = open_work_orders
  pts = load("city_curb_ramps.geojson")["features"].map do |f|
    lon, lat = f["geometry"]["coordinates"]
    [lat, lon, f["properties"]]
  end
  assign(pts, intersections).to_h do |key, recs|
    ns, ew = key[1].chars
    built = recs.select { built?(_1) }
    noramp = recs.select { blank(_1["CATEGORY"]) == "NORAMP" }
    stubs = recs.select { blank(_1["CATEGORY"]).empty? }
    covered = Set.new
    built.each do |r|
      d = blank(r["DIRECTION"])
      if blank(r["CATEGORY"]) == "SHARED" || d == OPPOSITE[ns] + OPPOSITE[ew]
        covered.merge(%w[main cross])
      elsif d == OPPOSITE[ew]
        covered << "main"
      elsif d == OPPOSITE[ns]
        covered << "cross"
      end
    end
    v = coverage_verdict(needs.fetch(key, []), covered, built.any?, noramp.any?, gaps_mean_missing: true)
    installs = built.filter_map { ms_to_date(_1["INSTALL_DATE"]) if _1["INSTALL_DATE"] }.sort
    observed = recs.flat_map do |r|
      %w[INSTALL_DATE VERIFICATION_DATE ASSESSMENT_DATE].filter_map { ms_to_date(r[_1]) if r[_1] }
    end.sort
    planned = (recs.flat_map { wo[_1["UNITID"]] }.uniq - [""]).sort
    [key, {
      "city" => built.any? || noramp.any? ? v : "unassessed",
      "city_covers" => covered.sort.join("+"),
      "city_ramp_count" => built.size,
      "city_noramp_count" => noramp.size,
      "city_placeholder_count" => stubs.size,
      "city_install_date" => installs.last.to_s,
      "city_last_observed" => observed.last.to_s,
      "city_condition" => (built.map { blank(_1["CONDITION"]) }.uniq - [""]).sort.join("/"),
      "city_ada" => (recs.map { blank(_1["ADA_COMPLIANT"]) }.uniq - [""]).sort.join("/"),
      "city_planned_project" => planned.join("; "),
      "city_ids" => recs.map { _1["UNITID"] }.sort.join(" "),
    }]
  end
end

def ps_evidence(intersections)
  pts = load("project_sidewalk_labels.geojson")["features"].filter_map do |f|
    p = f["properties"]
    next unless %w[CurbRamp NoCurbRamp].include?(p["label_type"]) && p["correct"] != false

    lon, lat = f["geometry"]["coordinates"]
    [lat, lon, p]
  end
  assign(pts, intersections).to_h do |key, labels|
    ramps = labels.select { _1["label_type"] == "CurbRamp" }
    noramp = labels.select { _1["label_type"] == "NoCurbRamp" }
    sev = ramps.filter_map { _1["severity"] }
    [key, {
      # Labels carry no reliable crossing direction, so a mix of CurbRamp and
      # NoCurbRamp at one corner is read as partial.
      "ps" => coverage_verdict([], Set.new, ramps.any?, noramp.any?),
      "ps_ramp_labels" => ramps.size,
      "ps_noramp_labels" => noramp.size,
      "ps_validated" => labels.count { _1["correct"] == true },
      "ps_ramp_max_severity" => sev.max.to_s,
      "ps_ramp_issues" => ramps.flat_map { _1["tags"] || [] }.uniq.sort.join("; "),
      "ps_image_date" => labels.filter_map { _1["image_capture_date"] }.max.to_s,
      "ps_label_ids" => labels.map { _1["label_id"] }.join(" "),
    }]
  end
end

OSM_PRESENT = %w[lowered flush no none].to_set.freeze
OSM_MISSING = %w[raised regular rolled yes].to_set.freeze

# kerb=* nodes; crossing direction comes from the crossing way's bearing.
def osm_evidence(nodes, ways, intersections, needs)
  crossing_ways = Hash.new { |h, k| h[k] = [] }
  ways.each do |w|
    t = w["tags"]
    next unless t["footway"] == "crossing" || (t["highway"] == "footway" && t.key?("crossing"))

    w["nodes"].each { crossing_ways[_1] << w }
  end

  crossing_kind = lambda do |n|
    crossing_ways[n["id"]].each do |w|
      a = nodes[w["nodes"].first]
      b = nodes[w["nodes"].last]
      next unless a && b

      x, y = to_xy(b["lat"], b["lon"], a["lat"], a["lon"])
      return "main" if x.abs > y.abs # Dayton runs N-S; an E-W crossing crosses it

      return "cross"
    end
    nil
  end

  pts = nodes.values.filter_map { [_1["lat"], _1["lon"], _1] if _1.dig("tags", "kerb") }
  assign(pts, intersections).to_h do |key, ns|
    covered = Set.new
    any_ramp = any_missing = false
    detail = ns.map do |n|
      k = n["tags"]["kerb"]
      kind = crossing_kind.call(n)
      if OSM_PRESENT.include?(k)
        any_ramp = true
        covered << kind if kind
      elsif OSM_MISSING.include?(k)
        any_missing = true
      end
      "#{kind || "?"}:#{k}"
    end
    need = needs.fetch(key, [])
    v = coverage_verdict(need, covered, any_ramp, any_missing)
    # Lowered kerb(s) mapped, but not for every crossing at this corner:
    # consistent with either present or partial, so it doesn't vote.
    v = "ramp (partly mapped)" if v == "present" && !need.all? { covered.include?(_1) }
    [key, {
      "osm" => v,
      "osm_kerbs" => detail.sort.join(" "),
      "osm_last_edit" => ns.filter_map { _1["timestamp"]&.slice(0, 10) }.max.to_s,
      "osm_node_ids" => ns.map { _1["id"] }.join(" "),
    }]
  end
end

# ---------------------------------------------------------------------------
# Combine
# ---------------------------------------------------------------------------

VOTING = %w[present partial missing].freeze

# [overall status, whether sources disagree, explanatory note]
def combine(row)
  votes = %w[city ps osm].to_h { [_1, row[_1]] }.select { |_, v| VOTING.include?(v) }
  return ["unknown", false, ""] if votes.empty?

  distinct = votes.values.uniq
  return [distinct.first, false, ""] if distinct.size == 1

  # If the city installed or verified the ramp after the other sources
  # looked, trust the city.
  city_seen = row["city_last_observed"].to_s
  if votes.key?("city") && !city_seen.empty?
    seen = { "ps" => row["ps_image_date"].to_s, "osm" => row["osm_last_edit"].to_s }
    others = votes.keys.reject { _1 == "city" || votes[_1] == votes["city"] }
    stale = others.select { !seen[_1].empty? && seen[_1] < city_seen[0, seen[_1].size] }
    if others.any? && stale == others
      return [votes["city"], true, "city record (#{city_seen}) is newer than #{stale.join("/")}"]
    end
  end

  # Everyone agrees a ramp is lacking somewhere: that's a need either way.
  if (distinct - %w[partial missing]).empty?
    return ["partial", true, "sources differ on whether one or both crossings lack a ramp"]
  end

  ["conflict", true, ""]
end

def load_requests
  path = File.join(ROOT, "data", "requests.csv")
  return {} unless File.exist?(path)

  CSV.read(path, headers: true).map(&:to_h).reject { _1["corner_id"].to_s.empty? }
     .to_h { [_1["corner_id"], _1] }
end

FIELDS = %w[
  corner_id intersection_id cross_street corner corner_type lat lon
  overall sources_disagree note
  city city_install_date city_last_observed city_covers
  city_ramp_count city_noramp_count city_placeholder_count
  city_condition city_ada city_planned_project city_ids
  ps ps_ramp_labels ps_noramp_labels ps_validated
  ps_ramp_max_severity ps_ramp_issues ps_image_date ps_label_ids
  osm osm_kerbs osm_last_edit osm_node_ids
  request_filed request_date request_ref request_status
].freeze

# Every built city ramp in the study area with its install date, for the
# "recent installs" background layer on the map.
def city_ramp_points
  load("city_curb_ramps.geojson")["features"].filter_map do |f|
    p = f["properties"]
    next unless built?(p)

    lon, lat = f["geometry"]["coordinates"]
    { "lat" => lat.round(6), "lon" => lon.round(6), "id" => p["UNITID"],
      "installed" => ms_to_date(p["INSTALL_DATE"]), "desc" => p["UNITDESC"],
      "condition" => blank(p["CONDITION"]) }
  end
end

def main
  nodes, ways = load_osm
  intersections = find_intersections(nodes, ways)
  corners = intersections.flat_map { corners_for(_1) }
  needs = corners.to_h { [[_1["intersection_id"], _1["corner"]], _1["needs"]] }
  city = city_evidence(intersections, needs)
  ps = ps_evidence(intersections)
  osm = osm_evidence(nodes, ways, intersections, needs)
  requests = load_requests

  rows = corners.map do |c|
    key = [c["intersection_id"], c["corner"]]
    row = FIELDS.to_h { [_1, ""] }
    row.merge!(c.except("needs"))
    row.merge!("city" => "no record", "ps" => "unknown", "osm" => "unknown")
    row.merge!(city.fetch(key, {}), ps.fetch(key, {}), osm.fetch(key, {}))
    overall, disagree, note = combine(row)
    note = [note, "SDOT planned: #{row["city_planned_project"]}"].reject(&:empty?).join("; ") unless row["city_planned_project"].empty?
    row.merge!("overall" => overall, "sources_disagree" => disagree ? "yes" : "", "note" => note)
    if (req = requests[c["corner_id"]])
      row.merge!("request_filed" => "yes", "request_date" => req["date_filed"].to_s,
                 "request_ref" => req["sdot_reference"].to_s, "request_status" => req["status"].to_s)
    end
    row
  end

  Dir.mkdir(OUT) unless Dir.exist?(OUT)
  CSV.open(File.join(OUT, "corners.csv"), "w") do |csv|
    csv << FIELDS
    rows.each { |r| csv << FIELDS.map { r[_1] == "" ? nil : r[_1] } }
  end

  fetched = { "city" => "city_curb_ramps.geojson", "ps" => "project_sidewalk_labels.geojson",
              "osm" => "osm.json" }.transform_values { load(_1)["_fetched"].to_s }
  geojson = {
    "type" => "FeatureCollection",
    "metadata" => { "fetched" => fetched },
    "features" => rows.map do |r|
      { "type" => "Feature",
        "geometry" => { "type" => "Point", "coordinates" => [r["lon"], r["lat"]] },
        "properties" => r.except("lat", "lon") }
    end,
  }
  File.write(File.join(OUT, "corners.geojson"), "#{JSON.pretty_generate(geojson)}\n")

  map_data = geojson.merge("city_ramps" => city_ramp_points)
  template = File.read(File.join(ROOT, "scripts", "map_template.html"))
  File.write(File.join(OUT, "map.html"), template.sub("/*__DATA__*/null") { JSON.generate(map_data) })

  puts "#{intersections.size} intersections: #{intersections.map { _1[:id] }.join(" ")}"
  puts "#{rows.size} corners"
  puts "overall: #{rows.map { _1["overall"] }.tally}"
  puts "sources disagree: #{rows.count { !_1["sources_disagree"].empty? }}"
  %w[city ps osm].each { |s| puts "  #{s}: #{rows.map { _1[s] }.tally}" }
end

main if $PROGRAM_NAME == __FILE__
