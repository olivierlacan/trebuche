#!/usr/bin/env ruby
# frozen_string_literal: true

# Build a per-corner curb ramp inventory for each street in data/areas.json.
#
# Reads data/raw/<area>/* (from fetch.rb) and data/requests.csv, and for each
# area writes:
#   output/<area>/corners.csv      one row per intersection corner
#   output/<area>/corners.geojson  same, as points
#   docs/<city>/<area>/data.js     data for this area's pages
#   docs/<city>/<area>/corners.csv copy of the CSV, linked from them
#   docs/<city>/<area>/index.html and map.html, from templates/area/*.erb
# plus docs/areas.js, a one-line summary per area for the home and city pages.
#
# Each corner can need up to two ramps: one for crossing the main street
# ("main") and one for crossing the side street ("cross"). A corner with only
# one of the two is "partial" -- for a stroller that is still a dead end.
#
# Standard library only. Run from the repo root:
#   ruby scripts/build.rb            # every area
#   ruby scripts/build.rb fremont    # just one (docs/areas.js still lists all)

require "csv"
require "erb"
require "fileutils"
require "json"
require "set"
require "time"

ROOT = File.expand_path("..", __dir__)
OUT_ROOT = File.join(ROOT, "output")
DOCS = File.join(ROOT, "docs")
TEMPLATES = File.join(ROOT, "templates", "area")
AREAS = JSON.parse(File.read(File.join(ROOT, "data", "areas.json")))

# One street at a time; set by use_area. Each lives on the website at
# docs/<city>/<neighborhood>/.
def use_area(a)
  $area = a.merge("extent" => "#{a["cross_abbr"]} #{ordinal(a["first"])} to #{a["cross_abbr"]} #{ordinal(a["last"])} St")
  $raw = File.join(ROOT, "data", "raw", a["slug"])
  $out = File.join(OUT_ROOT, a["slug"])
  $area_dir = File.join(DOCS, a["city_slug"], a["slug"])
end

MATCH_RADIUS_M = 30   # evidence farther than this from an intersection is ignored
CORNER_OFFSET_M = 9   # where to draw a corner marker, diagonally from the center
LEG_PROBE_M = 25      # a street node this far out along an axis means a leg exists
JOG_THRESHOLD_M = 10  # N and S approaches of Dayton offset by more than this = jog
APPROACH_M = 15       # how far up/down Dayton to sample its position
CROSS_OFFSET_M = 25   # side street legs offset N-S by more than this = two T-intersections

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
  JSON.parse(File.read(File.join($raw, name)))
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

# Intersections along the area's main street, found geometrically.
#
# Many Dayton intersections have neighborhood traffic circles where the named
# ways stop short of the center, so shared nodes can't be relied on. Dayton
# also jogs at N 64th and N 65th (the north and south halves of Dayton don't
# line up, so you turn briefly onto the side street to continue); each jog
# becomes two T-intersections.
def find_intersections(nodes, ways)
  main_segs = ways.select { _1.dig("tags", "name") == $area["osm_name"] }.flat_map do |w|
    pts = w["nodes"].filter_map { |n| nodes[n] && [nodes[n]["lat"], nodes[n]["lon"]] }
    pts.each_cons(2).to_a
  end
  main_lon = median(main_segs.map { _1[0][1] })

  cross_pts = Hash.new { |h, k| h[k] = [] }
  ways.each do |w|
    m = /\A#{$area["cross_prefix"]} (\d+)(?:st|nd|rd|th) Street\z/.match(w.dig("tags", "name").to_s)
    next unless m && ROAD_TYPES.include?(w["tags"]["highway"])

    num = m[1].to_i
    next unless ($area["first"]..$area["last"]).cover?(num)

    cross_pts[num].concat(w["nodes"].filter_map { |n| nodes[n] && [nodes[n]["lat"], nodes[n]["lon"]] })
  end

  cross_pts.keys.sort.flat_map do |num|
    pts = cross_pts[num]
    near = pts.select { (_1[1] - main_lon).abs * M_PER_DEG_LON < 80 }
    next [] if near.empty?

    # A side street that doesn't line up across the main street (Seattle's
    # "NE 82ND S ST" / "NE 82ND N ST") meets it as two T-intersections.
    lat0 = median(near.map(&:first))
    leg = ->(sign) { pts.select { |plat, plon| (plat - lat0).abs * M_PER_DEG_LAT < 60 && (sign * (plon - main_lon) * M_PER_DEG_LON).between?(LEG_PROBE_M, 150) }.map(&:first) }
    west = leg.call(-1)
    east = leg.call(1)
    if west.any? && east.any? && (median(west) - median(east)).abs * M_PER_DEG_LAT > CROSS_OFFSET_M
      (slat, sside), (nlat, nside) = [[median(west), "W"], [median(east), "E"]].sort
      [[slat, "S", sside], [nlat, "N", nside]].flat_map do |lat, suffix, side|
        intersections_at(num, lat, pts, main_segs, suffix:, side:)
      end
    else
      intersections_at(num, median(near.map(&:first)), pts, main_segs)
    end
  end
end

# The intersection(s) where cross street `num` meets the main street at `lat`.
# side: for an offset cross street, the one side ("W"/"E") it leaves from here.
def intersections_at(num, lat, pts, main_segs, suffix: "", side: nil)
  # Longitude of the main street APPROACH_M south (-1) or north (+1) of this street:
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
  return [] unless s_lon || n_lon # the main street doesn't reach this cross street

  centers =
    if s_lon && n_lon && (s_lon - n_lon).abs * M_PER_DEG_LON > JOG_THRESHOLD_M
      (wl, wd), (el, ed) = [[s_lon, "S"], [n_lon, "N"]].sort
      [[wl, "W", [wd]], [el, "E", [ed]]]
    else
      present = { "S" => s_lon, "N" => n_lon }.compact
      [[present.values.sum / present.size, "", present.keys]]
    end

  centers.map do |lon, jog_suffix, main_legs|
    legs = main_legs.to_set
    pts.each do |plat, plon|
      x, y = to_xy(plat, plon, lat, lon)
      leg = x.positive? ? "E" : "W"
      legs << leg if y.abs < 10 && x.abs > LEG_PROBE_M && (side.nil? || leg == side)
    end
    name = "#{$area["cross_abbr"]} #{ordinal(num)} St"
    # Main-street jog: "(west side of jog)". Offset cross street: "(east leg)".
    name += " (#{jog_suffix == "W" ? "west" : "east"} side of jog)" unless jog_suffix.empty?
    name += " (#{side == "W" ? "west" : "east"} leg)" if side
    { id: "#{num}#{suffix}#{jog_suffix}", cross_street: name, lat: lat, lon: lon,
      legs: %w[N E S W].select { legs.include?(_1) }.join }
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
      "corner_id" => "#{$area["id_prefix"]}-#{ix[:id]}-#{q}",
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

WORK_TYPES = ["Planned Construction", "Customer Service Request Curb Ramp"].freeze
RECENT_CLOSE_DAYS = 45

# SDOT curb ramp work orders that are open, or closed recently enough that the
# map might call them "ongoing" this week. Planned vs. ongoing is decided in
# the browser against the viewer's current date, so the site doesn't go stale
# between rebuilds.
def work_orders
  cutoff = Time.at(Time.now.to_i - RECENT_CLOSE_DAYS * 86_400).utc.strftime("%F")
  load("city_work_orders.geojson")["features"].filter_map do |f|
    a = f["properties"]
    next unless WORK_TYPES.include?(a["PROBLEMDESC"]) && a["CANCELLEDFLAG"] != "Y" && f["geometry"]

    closed = ms_to_date(a["CLOSEDDT"])
    next if !closed.empty? && closed < cutoff

    lon, lat = f["geometry"]["coordinates"]
    {
      "lat" => lat.round(6), "lon" => lon.round(6), "id" => a["UNITID"],
      "intersection" => blank(a["INT_UNITDESC"]),
      "kind" => a["PROBLEMDESC"] == "Planned Construction" ? "planned construction" : "resident request",
      "project" => blank(a["GROUPPROJNAME"]),
      "started" => ms_to_date(a["INITDTTM"] || a["WO_ADDDTTM"]),
      "est_complete" => ms_to_date(a["ESTCOMPDT"]),
      "closed" => closed,
    }
  end.uniq
end

def work_order_evidence(intersections, orders)
  assign(orders.map { [_1["lat"], _1["lon"], _1] }, intersections).to_h do |key, wos|
    [key, {
      "sdot_projects" => wos.map { _1["project"] }.uniq.reject(&:empty?).join("; "),
      "sdot_work" => wos.map { |w| "#{w["id"]} #{w["kind"]}" }.uniq.join("; "),
      "work_orders" => wos,
    }]
  end
end

# Where each corner actually is: the average of mapped curb points (SDOT ramp
# records and OSM kerb nodes) in that quadrant, so zooming to street level
# lands on the curb. Corners with no mapped points keep a fixed offset.
def precise_positions(intersections, nodes)
  pts = load("city_curb_ramps.geojson")["features"].map { _1["geometry"]["coordinates"].reverse }
  pts += nodes.values.filter_map { [_1["lat"], _1["lon"]] if _1.dig("tags", "kerb") }
  assign(pts.map { |lat, lon| [lat, lon, [lat, lon]] }, intersections).transform_values do |ll|
    [(ll.sum(&:first) / ll.size).round(6), (ll.sum(&:last) / ll.size).round(6)]
  end
end

def city_evidence(intersections, needs)
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
      return "main" if x.abs > y.abs # main streets run N-S; an E-W crossing crosses them

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
      "osm_covers" => covered.sort.join("+"),
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

# Checks neighbors made in person (data/field-checks.csv, pasted from the map's
# "Send checks" GitHub issues): which crossings had a ramp on the day.
# ramps_for is "main", "cross", "main+cross" or "none". The latest check per corner wins.
# ramp_issues says what's wrong with the ramps that are there ("no_warning+old_style";
# also "damaged", "lip"). distance_ft and accuracy_ft (phone location when saved) are
# kept for review, not used here.
def load_field_checks
  path = File.join(ROOT, "data", "field-checks.csv")
  return {} unless File.exist?(path)

  CSV.read(path, headers: true).map(&:to_h).reject { _1["corner_id"].to_s.empty? }
     .sort_by { _1["date_checked"].to_s }.to_h { [_1["corner_id"], _1] }
end

def field_verdict(check, needs)
  covered = check["ramps_for"].to_s.split("+") & %w[main cross]
  status = if needs.all? { covered.include?(_1) } then "present"
           elsif covered.empty? then "missing"
           else "partial"
           end
  [status, covered.sort.join("+"), (needs - covered)]
end

# Someone looked in person: that beats every remote source, unless the city
# recorded work there after the check.
def apply_field_check(row, check, needs)
  status, covers, gap = field_verdict(check, needs)
  date = check["date_checked"].to_s
  row.merge!("field" => status, "field_covers" => covers, "field_date" => date,
             "field_issues" => status == "missing" ? "" : check["ramp_issues"].to_s,
             "field_notes" => check["notes"].to_s)
  city_seen = row["city_last_observed"].to_s
  return false if !city_seen.empty? && city_seen > date

  others = %w[city ps osm].map { row[_1] }.select { VOTING.include?(_1) }
  row.merge!("overall" => status, "sources_disagree" => others.any? { _1 != status } ? "yes" : "",
             "note" => "checked in person #{date}",
             "confirmed_missing" => status == "missing" ? "yes" : "",
             "missing_crossings" => status == "present" ? "" : gap.join("+"))
  true
end

def load_requests
  path = File.join(ROOT, "data", "requests.csv")
  return {} unless File.exist?(path)

  CSV.read(path, headers: true).map(&:to_h).reject { _1["corner_id"].to_s.empty? }
     .to_h { [_1["corner_id"], _1] }
end

FIELDS = %w[
  corner_id intersection_id cross_street corner corner_type lat lon
  overall confirmed_missing needs missing_crossings sources_disagree note
  sdot_projects sdot_work
  city city_install_date city_last_observed city_covers
  city_ramp_count city_noramp_count city_placeholder_count
  city_condition city_ada city_ids
  ps ps_ramp_labels ps_noramp_labels ps_validated
  ps_ramp_max_severity ps_ramp_issues ps_image_date ps_label_ids
  osm osm_kerbs osm_last_edit osm_node_ids
  field field_covers field_date field_issues field_notes
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

def missing_crossings(row, needs)
  case row["overall"]
  when "missing" then needs
  when "partial"
    covered = (row["city_covers"].to_s.split("+") + row["osm_covers"].to_s.split("+")).uniq
    gap = needs - covered
    # Without knowing which crossing has the ramp, we can't say which lacks one.
    covered.empty? || gap.empty? ? ["unknown"] : gap
  else []
  end
end

def build_area
  nodes, ways = load_osm
  intersections = find_intersections(nodes, ways)
  corners = intersections.flat_map { corners_for(_1) }
  needs = corners.to_h { [[_1["intersection_id"], _1["corner"]], _1["needs"]] }
  city = city_evidence(intersections, needs)
  ps = ps_evidence(intersections)
  osm = osm_evidence(nodes, ways, intersections, needs)
  orders = work_orders
  wo = work_order_evidence(intersections, orders)
  positions = precise_positions(intersections, nodes)
  requests = load_requests
  checks = load_field_checks

  rows = corners.map do |c|
    key = [c["intersection_id"], c["corner"]]
    row = FIELDS.to_h { [_1, ""] }
    row.merge!(c.except("needs"))
    row["lat"], row["lon"] = positions[key] if positions[key]
    row.merge!("city" => "no record", "ps" => "unknown", "osm" => "unknown", "work_orders" => [])
    row.merge!(city.fetch(key, {}), ps.fetch(key, {}), osm.fetch(key, {}), wo.fetch(key, {}))
    overall, disagree, note = combine(row)
    row.merge!("overall" => overall, "sources_disagree" => disagree ? "yes" : "", "note" => note)
    row["confirmed_missing"] = "yes" if overall == "missing" && %w[city ps osm].count { row[_1] == "missing" } >= 2
    row["needs"] = c["needs"].join("+")
    row["missing_crossings"] = missing_crossings(row, c["needs"]).join("+")
    apply_field_check(row, checks[c["corner_id"]], c["needs"]) if checks[c["corner_id"]]
    if (req = requests[c["corner_id"]])
      row.merge!("request_filed" => "yes", "request_date" => req["date_filed"].to_s,
                 "request_ref" => req["sdot_reference"].to_s, "request_status" => req["status"].to_s)
    end
    row
  end

  FileUtils.mkdir_p($out)
  CSV.open(File.join($out, "corners.csv"), "w") do |csv|
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
  File.write(File.join($out, "corners.geojson"), "#{JSON.pretty_generate(geojson)}\n")

  # The website (docs/) loads its data from a plain script so it also works
  # when index.html is opened straight from disk.
  site = {
    "generated" => Time.now.utc.iso8601,
    "fetched" => fetched,
    "area" => $area.slice(*%w[city name slug street short cross_abbr first last extent id_prefix]),
    "corners" => rows,
    "city_ramps" => city_ramp_points,
    "work_orders" => orders,
  }
  FileUtils.mkdir_p($area_dir)
  File.write(File.join($area_dir, "data.js"),
             "// Generated by scripts/build.rb -- do not edit.\nwindow.RAMPS = #{JSON.generate(site)};\n")
  FileUtils.cp(File.join($out, "corners.csv"), File.join($area_dir, "corners.csv"))
  render_pages

  puts "== #{$area["street"]} (#{$area["name"]})"
  puts "#{intersections.size} intersections: #{intersections.map { _1[:id] }.join(" ")}"
  puts "#{rows.size} corners"
  puts "overall: #{rows.map { _1["overall"] }.tally}"
  puts "sources disagree: #{rows.count { !_1["sources_disagree"].empty? }}"
  %w[city ps osm].each { |s| puts "  #{s}: #{rows.map { _1[s] }.tally}" }

  # Small per-area summary for the home and city pages (so they don't have to
  # load every corner).
  $area.slice(*%w[city city_slug name slug street extent note]).merge(
    "path" => "#{$area["city_slug"]}/#{$area["slug"]}/",
    "generated" => site["generated"],
    "corners" => rows.size,
    "intersections" => intersections.size,
    "no_ramp" => rows.count { _1["confirmed_missing"] == "yes" },
    "one_crossing" => rows.count { _1["overall"] == "partial" },
    "both_crossings" => rows.count { _1["overall"] == "present" },
    "on_hold" => rows.count { _1["sdot_projects"].to_s.include?("on-hold") },
    "requests_filed" => rows.count { _1["request_filed"] == "yes" },
  )
end

# The area's landing page and map, from templates/area/*.erb. The templates
# see `a` (the area config plus "extent") and `esc` (HTML escaping).
def render_pages
  a = $area
  esc = ->(s) { ERB::Util.html_escape(s.to_s) }
  a["og_image"] = File.exist?(File.join($area_dir, "og.png")) ? "#{a["city_slug"]}/#{a["slug"]}/og.png" : "og.png"
  Dir[File.join(TEMPLATES, "*.erb")].each do |t|
    html = ERB.new(File.read(t), trim_mode: "-").result(binding)
    File.write(File.join($area_dir, File.basename(t, ".erb")), html)
  end
end

def main
  slugs = ARGV
  summaries_path = File.join(DOCS, "areas.js")
  previous = File.exist?(summaries_path) ? JSON.parse(File.read(summaries_path)[/\[.*\]/m]) : []
  summaries = AREAS.filter_map do |a|
    if slugs.empty? || slugs.include?(a["slug"])
      use_area(a)
      build_area
    else
      previous.find { _1["slug"] == a["slug"] }
    end
  end
  File.write(summaries_path,
             "// Generated by scripts/build.rb -- do not edit.\nwindow.AREAS = #{JSON.pretty_generate(summaries)};\n")
end

main if $PROGRAM_NAME == __FILE__
