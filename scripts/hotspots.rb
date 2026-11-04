#!/usr/bin/env ruby
# frozen_string_literal: true

# Citywide scan for clusters of intersections with no curb ramps, in Seattle.
#
# For every SDOT intersection it combines:
#   - SDOT's curb ramp inventory (built ramps linked to the intersection)
#   - Project Sidewalk's per-intersection "access score" clusters
#     (volunteer labels of CurbRamp / NoCurbRamp from street imagery)
#   - SDOT's sidewalk inventory, to tell "no ramp where there is a sidewalk"
#     (fixable with a ramp) from "no sidewalk at all" (a different problem)
# and groups intersections into ~450 m grid cells, then merges side-by-side
# busy cells into hotspots, named after the city's Community Reporting Areas
# and council districts.
#
# Writes docs/seattle/hotspots/data.js. Raw downloads are cached in
# data/raw/citywide/ (pass --refresh to download again).
#
# Standard library only. Run from the repo root:  ruby scripts/hotspots.rb

require "fileutils"
require "json"
require "net/http"
require "set"
require "time"
require "uri"

ROOT = File.expand_path("..", __dir__)
RAW = File.join(ROOT, "data", "raw", "citywide")
OUT_DIR = File.join(ROOT, "docs", "seattle", "hotspots")
AREAS = JSON.parse(File.read(File.join(ROOT, "data", "areas.json")))

ARCGIS = "https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services"
SEATTLE_BBOX = [-122.46, 47.48, -122.22, 47.74] # W S E N
PS_URL = "https://sidewalk-sea.cs.washington.edu/v3/api/accessScoreIntersections"
UA = "trebuche-curb-ramp-survey/0.1 (neighborhood accessibility project)"

MATCH_M = 25        # Project Sidewalk intersection / sidewalk end this close counts
CELL_LAT = 0.004    # grid cell, about 445 m north-south
CELL_LON = 0.006    # and 450 m east-west at Seattle's latitude
HOT_MIN = 6         # a cell with at least this many no-ramp intersections is "hot"
M_LAT = 111_320.0
M_LON = 111_320.0 * Math.cos(47.62 * Math::PI / 180)

def http_json(url, params)
  uri = URI(url)
  uri.query = URI.encode_www_form(params)
  req = Net::HTTP::Get.new(uri)
  req["User-Agent"] = UA
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 30, read_timeout: 600) { _1.request(req) }
  raise "HTTP #{res.code} from #{uri.host}" unless res.is_a?(Net::HTTPSuccess)

  JSON.parse(res.body)
end

# Every feature of an SDOT layer, 2000 at a time.
def arcgis_all(layer, fields, geometry: true)
  feats = []
  loop do
    d = http_json("#{ARCGIS}/#{layer}/FeatureServer/0/query",
                  where: "1=1", outFields: fields, returnGeometry: geometry, outSR: 4326,
                  geometryPrecision: 6, orderByFields: "OBJECTID",
                  resultOffset: feats.size, resultRecordCount: 2000, f: geometry ? "geojson" : "json")
    page = d["features"]
    feats.concat(page)
    print "\r  #{layer}: #{feats.size}"
    break if page.size < 2000 && !(d["exceededTransferLimit"] || d.dig("properties", "exceededTransferLimit"))
  end
  puts
  feats
end

def cached(name, refresh)
  path = File.join(RAW, name)
  return JSON.parse(File.read(path)) if File.exist?(path) && !refresh

  data = yield
  File.write(path, JSON.generate(data))
  data
end

def fetch(refresh)
  FileUtils.mkdir_p(RAW)
  ints = cached("intersections.json", refresh) do
    arcgis_all("SDOT_Intersections", "UNITID,UNITDESC,ARTERIALCLASSCD").map do |f|
      lon, lat = f["geometry"]["coordinates"]
      p = f["properties"]
      [p["UNITID"], p["UNITDESC"], p["ARTERIALCLASSCD"], lat, lon]
    end
  end
  ramps = cached("ramps.json", refresh) do
    arcgis_all("Curb_Ramps_(Active)", "INT_UNITID,CATEGORY", geometry: false)
      .map { [_1["attributes"]["INT_UNITID"], _1["attributes"]["CATEGORY"].to_s.strip] }
  end
  # Only the ends of each sidewalk segment matter: that's where they meet a corner.
  sidewalks = cached("sidewalk_ends.json", refresh) do
    arcgis_all("Sidewalks_(Active)", "SURFTYPE,SW_CATEGORY").filter_map do |f|
      g = f["geometry"]
      next unless g && f["properties"]["SW_CATEGORY"] == "BLOCK"

      lines = g["type"] == "MultiLineString" ? g["coordinates"] : [g["coordinates"]]
      improved = f["properties"]["SURFTYPE"] != "UIMPRV"
      lines.flat_map { [_1.first, _1.last] }.map { |lon, lat| [lat.round(6), lon.round(6), improved ? 1 : 0] }
    end.flatten(1)
  end
  ps = cached("ps_intersections.json", refresh) do
    puts "  Project Sidewalk intersections (slow) ..."
    http_json(PS_URL, bbox: SEATTLE_BBOX.join(","))["features"].map do |f|
      lon, lat = f["geometry"]["coordinates"]
      cc = f["properties"]["cluster_counts"]
      [lat, lon, cc["CurbRamp"], cc["NoCurbRamp"]]
    end
  end
  hoods = cached("neighborhoods.json", refresh) do
    arcgis_all("neighborhood_map_layers", "NEIGH_NAME,NEIGH_TYPE,TOTAL_POPULATION,POPULATION_DISABILITY_PERC,Children_under_5,Older_Adults_65_over")
      .map { { "props" => _1["properties"], "geometry" => _1["geometry"] } }
  end
  [ints, ramps, sidewalks, ps, hoods]
end

# ---------------------------------------------------------------- geometry

class Grid
  def initialize(points, cell = 0.0005) # ~55 m buckets
    @cell = cell
    @h = Hash.new { |h, k| h[k] = [] }
    points.each { |pt| @h[key(pt[0], pt[1])] << pt }
  end

  def key(lat, lon) = [(lat / @cell).floor, (lon / @cell).floor]

  def near(lat, lon, radius_m)
    kl, ko = key(lat, lon)
    out = []
    (-1..1).each do |a|
      (-1..1).each do |b|
        @h[[kl + a, ko + b]].each do |pt|
          d = Math.hypot((pt[0] - lat) * M_LAT, (pt[1] - lon) * M_LON)
          out << [d, pt] if d <= radius_m
        end
      end
    end
    out.sort_by(&:first).map(&:last)
  end
end

def ring_contains?(ring, lon, lat)
  inside = false
  ring.each_cons(2) do |(x1, y1), (x2, y2)|
    inside = !inside if (y1 > lat) != (y2 > lat) && lon < (x2 - x1) * (lat - y1) / (y2 - y1) + x1
  end
  inside
end

def polygon_contains?(geom, lon, lat)
  polys = geom["type"] == "MultiPolygon" ? geom["coordinates"] : [geom["coordinates"]]
  polys.any? { |rings| ring_contains?(rings[0], lon, lat) && rings[1..].none? { ring_contains?(_1, lon, lat) } }
end

def bbox_of(geom)
  pts = (geom["type"] == "MultiPolygon" ? geom["coordinates"].flatten(2) : geom["coordinates"].flatten(1))
  lons, lats = pts.map(&:first), pts.map(&:last)
  [lons.min, lats.min, lons.max, lats.max]
end

# ---------------------------------------------------------------- analysis

def classify(ints, ramps, sidewalks, ps)
  built = Hash.new(0)
  noramp = Hash.new(0)
  ramps.each do |int_id, cat|
    built[int_id] += 1 if %w[SINGLE SHARED].include?(cat)
    noramp[int_id] += 1 if cat == "NORAMP"
  end
  sw = Grid.new(sidewalks)
  psg = Grid.new(ps)

  ints.filter_map do |id, desc, art, lat, lon|
    streets = desc.to_s.split(" AND ")
    next unless streets.size == 2 && lat
    next if streets.any? { _1.match?(/DEAD END|ALLEY|\bRAMP\b|\bOFF\b|\bON\b|EXIT|PRIVATE|^\d+$/) }

    ends = sw.near(lat, lon, MATCH_M)
    sidewalk = ends.any? { _1[2] == 1 } ? "yes" : ends.empty? ? "unmapped" : "no"
    p = psg.near(lat, lon, MATCH_M).first
    status =
      if built[id].positive? then "ramps"
      elsif noramp[id].positive? || (p && p[3].to_i.positive? && p[2].to_i.zero?) then "none"
      else "unknown"
      end
    { id:, streets:, art:, lat:, lon:, status:, sidewalk:, ps: !p.nil?, ramps: built[id] }
  end
end

# type: "CRA" (Community Reporting Area, the city's neighborhood map) or "CD" (council district)
def neighborhood_lookup(hoods, type)
  indexed = hoods.select { _1["geometry"] && _1["props"]["NEIGH_TYPE"] == type }.map { [_1, bbox_of(_1["geometry"])] }
  lambda do |lat, lon|
    hit = indexed.find do |h, (w, s, e, n)|
      lon.between?(w, e) && lat.between?(s, n) && polygon_contains?(h["geometry"], lon, lat)
    end
    hit&.first
  end
end

# Street-name tidy-up for display: "NW 73RD ST" -> "NW 73rd St".
def pretty(street)
  street.split.map do |w|
    if w.match?(/\A(N|S|E|W|NE|NW|SE|SW)\z/) then w
    elsif w.match?(/\A\d+(ST|ND|RD|TH)\z/) then w.downcase
    else w.capitalize
    end
  end.join(" ").sub(/ (N|S|E|W|NE|NW|SE|SW) St\z/) { " #{$1} St" }
end

def hotspots(rows, hood_of, district_of)
  actionable = rows.select { _1[:status] == "none" && _1[:sidewalk] == "yes" }
  cells = actionable.group_by { [(_1[:lat] / CELL_LAT).floor, (_1[:lon] / CELL_LON).floor] }
  hot = cells.select { |_, v| v.size >= HOT_MIN }

  # Merge touching hot cells (8-neighbors) into one hotspot.
  seen = Set.new
  clusters = hot.keys.sort_by { -hot[_1].size }.filter_map do |start|
    next if seen.include?(start)

    group, queue = [], [start]
    seen << start
    until queue.empty?
      c = queue.shift
      group << c
      [[-1, 0], [1, 0], [0, -1], [0, 1]].each do |a, b|
        n = [c[0] + a, c[1] + b]
        next if seen.include?(n) || !hot.key?(n)

        seen << n
        queue << n
      end
    end
    group
  end

  all_by_cell = rows.group_by { [(_1[:lat] / CELL_LAT).floor, (_1[:lon] / CELL_LON).floor] }
  clusters.map do |group|
    none = group.flat_map { hot[_1] }
    everything = group.flat_map { all_by_cell[_1] || [] }
    with_sidewalk = everything.select { _1[:sidewalk] == "yes" }
    lat = none.sum { _1[:lat] } / none.size
    lon = none.sum { _1[:lon] } / none.size
    names = none.filter_map { hood_of.call(_1[:lat], _1[:lon])&.dig("props", "NEIGH_NAME") }.tally.sort_by { -_2 }
    streets = none.flat_map { _1[:streets] }.tally.sort_by { |s, n| [-n, s] }.first(4)
    lats = group.map(&:first)
    lons = group.map(&:last)
    districts = none.filter_map { district_of.call(_1[:lat], _1[:lon])&.dig("props", "NEIGH_NAME") }.tally.sort_by { -_2 }
    {
      "name" => names.first(2).map(&:first).join(" / "),
      "district" => districts.map { _1[0].sub("Council District ", "") }.join(", "),
      "lat" => lat.round(5), "lon" => lon.round(5),
      "bounds" => [[lats.min * CELL_LAT, lons.min * CELL_LON], [(lats.max + 1) * CELL_LAT, (lons.max + 1) * CELL_LON]]
                  .map { |a| a.map { _1.round(5) } },
      "no_ramp" => none.size,
      "with_sidewalk" => with_sidewalk.size,
      "share" => (100.0 * none.size / [with_sidewalk.size, 1].max).round,
      "unknown" => with_sidewalk.count { _1[:status] == "unknown" },
      "streets" => streets.map { |s, n| [pretty(s), n] },
      "page" => AREAS.find { |a| a["bbox"] && lat.between?(a["bbox"][0] - 0.004, a["bbox"][2] + 0.004) && lon.between?(a["bbox"][1] - 0.006, a["bbox"][3] + 0.006) }
                     &.then { "../#{_1["slug"]}/" },
    }
  end.sort_by { -_1["no_ramp"] }
end

def neighborhood_stats(rows, hood_of)
  by = rows.select { _1[:sidewalk] == "yes" }.group_by { hood_of.call(_1[:lat], _1[:lon]) }
  by.delete(nil)
  by.map do |h, rs|
    p = h["props"]
    {
      "name" => p["NEIGH_NAME"], "intersections" => rs.size,
      "no_ramp" => rs.count { _1[:status] == "none" },
      "ramps" => rs.count { _1[:status] == "ramps" },
      "unknown" => rs.count { _1[:status] == "unknown" },
      "ps_coverage" => (100.0 * rs.count { _1[:ps] } / rs.size).round,
      "disability_pct" => p["POPULATION_DISABILITY_PERC"]&.round(1),
      "under_5" => p["Children_under_5"], "over_65" => p["Older_Adults_65_over"],
      "population" => p["TOTAL_POPULATION"],
    }
  end.select { _1["intersections"] >= 20 }.sort_by { -_1["no_ramp"] }
end

def main
  ints, ramps, sidewalks, ps, hoods = fetch(ARGV.include?("--refresh"))
  rows = classify(ints, ramps, sidewalks, ps)
  hood_of = neighborhood_lookup(hoods, "CRA")
  district_of = neighborhood_lookup(hoods, "CD")
  spots = hotspots(rows, hood_of, district_of)
  stats = neighborhood_stats(rows, hood_of)

  FileUtils.mkdir_p(OUT_DIR)
  points = rows.map { [_1[:lat].round(5), _1[:lon].round(5), { "ramps" => 1, "none" => 2, "unknown" => 0 }[_1[:status]],
                       _1[:sidewalk] == "yes" ? 1 : 0, _1[:streets].map { |s| pretty(s) }.join(" & ")] }
  data = {
    "generated" => Time.now.utc.iso8601,
    "totals" => {
      "intersections" => rows.size,
      "with_sidewalk" => rows.count { _1[:sidewalk] == "yes" },
      "no_ramp" => rows.count { _1[:status] == "none" && _1[:sidewalk] == "yes" },
      "no_ramp_no_sidewalk" => rows.count { _1[:status] == "none" && _1[:sidewalk] != "yes" },
      "ramps" => rows.count { _1[:status] == "ramps" && _1[:sidewalk] == "yes" },
      "unknown" => rows.count { _1[:status] == "unknown" && _1[:sidewalk] == "yes" },
    },
    "cell" => [CELL_LAT, CELL_LON], "hot_min" => HOT_MIN,
    "hotspots" => spots, "neighborhoods" => stats,
    "points" => points,
  }
  # A few numbers for pages that link here, without loading every point.
  summary = data["totals"].slice("no_ramp", "with_sidewalk").merge(
    "hotspots" => spots.size, "generated" => data["generated"],
    "top" => spots.first(3).map { _1.slice("name", "no_ramp") },
  )
  File.write(File.join(OUT_DIR, "summary.js"),
             "// Generated by scripts/hotspots.rb -- do not edit.\nwindow.HOTSPOT_SUMMARY = #{JSON.generate(summary)};\n")
  File.write(File.join(OUT_DIR, "data.js"),
             "// Generated by scripts/hotspots.rb -- do not edit.\nwindow.HOTSPOTS = #{JSON.generate(data)};\n")

  puts "#{rows.size} intersections; totals #{data["totals"]}"
  puts "\nTop hotspots:"
  spots.first(20).each_with_index do |s, i|
    puts format("%2d. %-36s D%-4s %3d no-ramp of %3d with sidewalks (%2d%%)  %s", i + 1, s["name"], s["district"], s["no_ramp"], s["with_sidewalk"],
                s["share"], s["streets"].map { |n, c| "#{n} (#{c})" }.join(", "))
  end
  puts "\nNeighborhoods with the most:"
  stats.first(15).each do |n|
    puts format("  %-26s %3d no-ramp / %3d  PS coverage %3d%%  disability %s%%", n["name"], n["no_ramp"], n["intersections"], n["ps_coverage"], n["disability_pct"])
  end
end

main if $PROGRAM_NAME == __FILE__
