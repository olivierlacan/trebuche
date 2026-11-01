#!/usr/bin/env ruby
# frozen_string_literal: true

# Download curb ramp data for the Dayton Ave N study area into data/raw/.
#
# Sources:
#   1. SDOT "Curb Ramps (Active)" and "Curb Ramp Work Orders" ArcGIS feature
#      services (Seattle GeoData)
#   2. Project Sidewalk Seattle v3 rawLabels API
#   3. OpenStreetMap (Overpass API, falling back to the OSM editing API in tiles)
#
# Standard library only. Run from the repo root:
#   ruby scripts/fetch.rb            # everything
#   ruby scripts/fetch.rb city osm   # just some sources

require "json"
require "net/http"
require "time"
require "uri"

ROOT = File.expand_path("..", __dir__)
RAW = File.join(ROOT, "data", "raw")

# Study area: Dayton Ave N, N 60th St to N 85th St, padded a little so corner
# points just outside the nominal box are still captured.
SOUTH, WEST, NORTH, EAST = 47.668, -122.362, 47.693, -122.348

# Narrow corridor around Dayton Ave N (lon ~ -122.3527) for OSM, which is dense
# with building nodes and would exceed the OSM API's 50k-node limit otherwise.
OSM_WEST, OSM_EAST = -122.3550, -122.3505

ARCGIS = "https://services.arcgis.com/ZOyb2t4B0UYuYNYH/arcgis/rest/services"
CITY_URL = "#{ARCGIS}/Curb_Ramps_(Active)/FeatureServer/0/query"
CITY_WO_URL = "#{ARCGIS}/Curb_Ramp_Work_Orders/FeatureServer/0/query"
PS_URL = "https://sidewalk-sea.cs.washington.edu/v3/api/rawLabels"
OVERPASS_URLS = %w[
  https://overpass-api.de/api/interpreter
  https://maps.mail.ru/osm/tools/overpass/api/interpreter
].freeze
OSM_API_URL = "https://api.openstreetmap.org/api/0.6/map.json"

UA = "trebuche-curb-ramp-survey/0.1 (neighborhood accessibility project)"

def http(url, params: nil, form: nil, timeout: 120)
  uri = URI(url)
  uri.query = URI.encode_www_form(params) if params
  req = form ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
  req["User-Agent"] = UA
  req.set_form_data(form) if form
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                        open_timeout: 30, read_timeout: timeout) { _1.request(req) }
  raise "HTTP #{res.code} from #{uri.host}" unless res.is_a?(Net::HTTPSuccess)

  JSON.parse(res.body)
end

def save(name, obj, source_url)
  path = File.join(RAW, name)
  meta = { "_fetched" => Time.now.utc.iso8601, "_source" => source_url }
  File.write(path, JSON.generate(meta.merge(obj)))
  puts "  wrote #{path.delete_prefix("#{ROOT}/")}"
end

def arcgis_params(out_fields)
  {
    geometry: [WEST, SOUTH, EAST, NORTH].join(","),
    geometryType: "esriGeometryEnvelope",
    inSR: 4326, outSR: 4326,
    spatialRel: "esriSpatialRelIntersects",
    where: "1=1",
    outFields: out_fields,
    resultRecordCount: 2000,
    f: "geojson",
  }
end

def fetch_city
  puts "SDOT curb ramps ..."
  d = http(CITY_URL, params: arcgis_params("*"))
  abort "City query exceeded transfer limit; add paging." if d.dig("properties", "exceededTransferLimit")
  puts "  #{d["features"].size} ramp records"
  save("city_curb_ramps.geojson", d, CITY_URL)
end

def fetch_city_work_orders
  puts "SDOT curb ramp work orders ..."
  # WORKDESC is deliberately excluded: it can contain residents' names and
  # contact details copied from service requests.
  fields = %w[UNITID INT_UNITDESC CURRENT_STATUS CANCELLEDFLAG CLOSEDDT
              ESTCOMPDT GROUPPROJNAME PROBLEMDESC SOURCE WO_ADDDTTM]
  d = http(CITY_WO_URL, params: arcgis_params(fields.join(",")))
  puts "  #{d["features"].size} work orders"
  save("city_work_orders.geojson", d, CITY_WO_URL)
end

def fetch_project_sidewalk
  puts "Project Sidewalk labels ..."
  d = http(PS_URL, params: { bbox: [WEST, SOUTH, EAST, NORTH].join(",") }, timeout: 300)
  puts "  #{d["features"].size} labels"
  save("project_sidewalk_labels.geojson", d, PS_URL)
end

def fetch_osm
  puts "OpenStreetMap ..."
  bbox = [SOUTH, OSM_WEST, NORTH, OSM_EAST].join(",")
  query = <<~Q
    [out:json][timeout:90];
    (
      node(#{bbox})[kerb];
      node(#{bbox})[highway=crossing];
      way(#{bbox})[highway];
    );
    (._; >;);
    out meta;
  Q
  OVERPASS_URLS.each do |url|
    d = http(url, form: { "data" => query }, timeout: 150)
    puts "  #{d["elements"].size} elements via #{url}"
    return save("osm.json", { "elements" => d["elements"] }, url)
  rescue StandardError => e
    puts "  #{url} failed: #{e.class}: #{e.message}"
  end

  # Fallback: OSM editing API, tiled north-south along the corridor. Ways are
  # clipped at tile edges, which is fine for corner-scale analysis.
  puts "  falling back to OSM API tiles"
  elements = {}
  lat = SOUTH
  while lat < NORTH
    top = [lat + 0.005, NORTH].min
    d = http(OSM_API_URL, params: { bbox: [OSM_WEST, lat, OSM_EAST, top].join(",") }, timeout: 180)
    d["elements"].each { elements[[_1["type"], _1["id"]]] = _1 }
    puts format("    tile %.3f-%.3f: %d elements", lat, top, d["elements"].size)
    lat = top
    sleep 1 # be polite to the OSM API
  end
  save("osm.json", { "elements" => elements.values }, OSM_API_URL)
end

if $PROGRAM_NAME == __FILE__
  Dir.mkdir(RAW) unless Dir.exist?(RAW)
  which = ARGV.empty? ? %w[city ps osm] : ARGV
  if which.include?("city")
    fetch_city
    fetch_city_work_orders
  end
  fetch_project_sidewalk if which.include?("ps")
  fetch_osm if which.include?("osm")
end
