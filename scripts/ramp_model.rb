#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes a true-scale 3D model of a City of Seattle Type 422A perpendicular
# curb ramp as binary glTF (docs/ar/ramp-422a.glb), for the AR preview page.
#
# Dimensions follow the 2026 City of Seattle Standard Plans:
#   422a  ramp at least 4'-0" wide (drawn 5'-0"), 8.3% max running slope,
#         wings at 10% max, landing at least 4'-0" deep and as wide as the ramp
#   422k  detectable warning 2'-0" deep across the full ramp, truncated domes
#         (base 0.9"-1.4", top 50-65% of base, 0.2" tall, 1.6"-2.4" apart) in an
#         in-line grid aligned with the ramp; 4'-0" x 4'-0" clear area at the bottom
# Seattle's standard curb is 6" tall, which sets the ramp run (6'-0" at 8.3%)
# and the wing length along the curb (5'-0" at 10%).
#
# Units are meters, Y is up, the street side faces +Z, and the origin is on the
# street surface at the curb face, centered on the ramp. Standard library only.
#
#   ruby scripts/ramp_model.rb            # writes docs/ar/ramp-422a.glb
#   ruby scripts/ramp_model.rb --check    # also prints dimensions measured from the mesh

require "json"

FT = 0.3048
IN = FT / 12

CURB_H   = 6 * IN                 # 6" curb
RAMP_W   = 5 * FT                 # 5'-0" ramp
RUN      = CURB_H / 0.083         # 8.3% max running slope -> ~6'-0"
WING     = CURB_H / 0.10          # 10% max wing slope along the curb -> 5'-0"
LANDING  = 4 * FT                 # 4'-0" landing
WARN     = 2 * FT                 # 2'-0" detectable warning
CLEAR    = 4 * FT                 # 4'-0" x 4'-0" clear area on the street
STUB     = 2 * FT                 # curb/sidewalk shown past each wing, for context
JOINT_W  = 0.012                  # drawn width of a joint line
LIFT     = 0.0015                 # small lift for surface details (avoids z-fighting)

DOME_BASE    = 1.15 * IN
DOME_TOP     = 0.6 * DOME_BASE
DOME_H       = 0.2 * IN
DOME_SPACING = 2.35 * IN

MATERIALS = {
  "ramp"     => { color: "#d9d3c5", rough: 0.92 },
  "wing"     => { color: "#d2ccbd", rough: 0.92 },
  "sidewalk" => { color: "#c8c1b2", rough: 0.95 },
  "curb"     => { color: "#b5ad9b", rough: 0.9 },
  "warning"  => { color: "#f2b51c", rough: 0.6 },  # Federal Safety Yellow (approx.)
  "joint"    => { color: "#6a6354", rough: 1.0 },
  "paint"    => { color: "#f4f1ea", rough: 0.7 },
}.freeze

class Mesh
  attr_reader :tris

  def initialize = @tris = Hash.new { |h, k| h[k] = [] }

  # Flat-shaded triangle; vertices counter-clockwise when seen from the front.
  def tri(mat, a, b, c) = @tris[mat] << [a, b, c]

  def quad(mat, a, b, c, d)
    tri(mat, a, b, c)
    tri(mat, a, c, d)
  end

  # Convex polygon, fan-triangulated.
  def poly(mat, pts) = (1...pts.size - 1).each { |i| tri(mat, pts[0], pts[i], pts[i + 1]) }

  # Box from two corners (for thin strips and slabs).
  def box(mat, (x0, y0, z0), (x1, y1, z1))
    quad(mat, [x0, y1, z1], [x1, y1, z1], [x1, y1, z0], [x0, y1, z0]) # top
    quad(mat, [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]) # front (+z)
    quad(mat, [x1, y0, z0], [x0, y0, z0], [x0, y1, z0], [x1, y1, z0]) # back
    quad(mat, [x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [x0, y1, z0]) # left
    quad(mat, [x1, y0, z1], [x1, y0, z0], [x1, y1, z0], [x1, y1, z1]) # right
  end
end

def add(a, b) = a.zip(b).map { _1 + _2 }
def scale(a, s) = a.map { _1 * s }

def build
  m = Mesh.new
  hw = RAMP_W / 2
  zt = -RUN                 # top of ramp
  zl = -RUN - LANDING       # back of landing
  xs = hw + WING + STUB     # outer edge of the context stubs
  h = CURB_H

  # Ramp run: rises from the street (z = 0) to the sidewalk (z = -RUN).
  m.quad("ramp", [-hw, 0, 0], [hw, 0, 0], [hw, h, zt], [-hw, h, zt])
  # Wings: triangles sloping down to the ramp, and the curb face under each one.
  m.tri("wing", [-hw, 0, 0], [-hw, h, zt], [-hw - WING, h, 0])
  m.tri("wing", [hw, 0, 0], [hw + WING, h, 0], [hw, h, zt])
  m.tri("curb", [-hw, 0, 0], [-hw - WING, h, 0], [-hw - WING, 0, 0])
  m.tri("curb", [hw, 0, 0], [hw + WING, 0, 0], [hw + WING, h, 0])
  # Landing and the sidewalk around it (level at curb height).
  m.quad("ramp", [-hw, h, zt], [hw, h, zt], [hw, h, zl], [-hw, h, zl])
  m.poly("sidewalk", [[-xs, h, 0], [-hw - WING, h, 0], [-hw, h, zt], [-hw, h, zl], [-xs, h, zl]])
  m.poly("sidewalk", [[xs, h, 0], [xs, h, zl], [hw, h, zl], [hw, h, zt], [hw + WING, h, 0]])
  # Curb faces of the stubs, and the slab's outer edges.
  m.quad("curb", [-xs, 0, 0], [-hw - WING, 0, 0], [-hw - WING, h, 0], [-xs, h, 0])
  m.quad("curb", [hw + WING, 0, 0], [xs, 0, 0], [xs, h, 0], [hw + WING, h, 0])
  m.quad("curb", [-xs, 0, zl], [-xs, 0, 0], [-xs, h, 0], [-xs, h, zl])
  m.quad("curb", [xs, 0, 0], [xs, 0, zl], [xs, h, zl], [xs, h, 0])
  m.quad("curb", [xs, 0, zl], [-xs, 0, zl], [-xs, h, zl], [xs, h, zl])

  # Detectable warning panel on the ramp, with truncated domes.
  slope_y = h / RUN                                  # rise per meter of run
  surf = ->(x, z) { [x, -z * slope_y, z] }           # point on the ramp surface
  len = Math.sqrt(1 + slope_y**2)
  n = [0, 1 / len, slope_y / len]                    # ramp surface normal
  t = [0, slope_y / len, -1 / len]                   # up-slope direction
  up = scale(n, LIFT)
  m.quad("warning", add(surf[-hw, 0], up), add(surf[hw, 0], up), add(surf[hw, -WARN], up), add(surf[-hw, -WARN], up))
  cols = (RAMP_W / DOME_SPACING).floor
  rows = (WARN / DOME_SPACING).floor
  x0 = -(cols - 1) * DOME_SPACING / 2
  z0 = -(WARN - (rows - 1) * DOME_SPACING) / 2
  seg = 10
  rows.times do |r|
    cols.times do |c|
      base = add(surf[x0 + c * DOME_SPACING, z0 - r * DOME_SPACING], up)
      ring = lambda do |radius, lift|
        Array.new(seg) do |i|
          a = 2 * Math::PI * i / seg
          add(add(base, scale(n, lift)), add(scale([1, 0, 0], radius * Math.cos(a)), scale(t, radius * Math.sin(a))))
        end
      end
      b = ring.(DOME_BASE / 2, 0)
      top = ring.(DOME_TOP / 2, DOME_H)
      seg.times do |i|
        j = (i + 1) % seg
        m.quad("warning", b[i], b[j], top[j], top[i])
      end
      m.poly("warning", top)
    end
  end

  # Through joints: along each wing, across the top of the ramp, around the landing.
  joint = lambda do |a, b|
    dx, dz = b[0] - a[0], b[2] - a[2]
    l = Math.hypot(dx, dz)
    ox, oz = -dz / l * JOINT_W / 2, dx / l * JOINT_W / 2
    lift = [0, LIFT * 2, 0]
    m.quad("joint", add([a[0] + ox, a[1], a[2] + oz], lift), add([b[0] + ox, b[1], b[2] + oz], lift),
           add([b[0] - ox, b[1], b[2] - oz], lift), add([a[0] - ox, a[1], a[2] - oz], lift))
  end
  joint.([-hw - WING, h, 0], [-hw, h, zt])
  joint.([-hw, h, zt], [hw, h, zt])
  joint.([hw, h, zt], [hw + WING, h, 0])
  joint.([-hw, h, zt], [-hw, h, zl])
  joint.([-hw, h, zl], [hw, h, zl])
  joint.([hw, h, zl], [hw, h, zt])

  # The 4' x 4' clear area on the street, as a dashed white outline: the far
  # edge (parallel to the curb) and both sides (running out from the curb).
  half = CLEAR / 2
  dash, w = 0.15, 0.025
  dashes = ->(from, to) { (from...to).step(dash * 2).map { [_1, [_1 + dash, to].min] } }
  dashes.(-half, half).each { |a, b| m.box("paint", [a, 0, CLEAR - w / 2], [b, LIFT, CLEAR + w / 2]) }
  [-half, half].each do |x|
    dashes.(0.02, CLEAR).each { |a, b| m.box("paint", [x - w / 2, 0, a], [x + w / 2, LIFT, b]) }
  end
  m
end

# ---------------------------------------------------------------- glTF writer

def hex_rgb(hex) = hex.delete("#").scan(/../).map { (_1.to_i(16) / 255.0)**2.2 } # sRGB -> linear

def to_glb(mesh)
  bin = +"".b
  views, accessors, prims, materials = [], [], [], []
  MATERIALS.each_with_index do |(name, spec), mi|
    materials << { "name" => name,
                   "pbrMetallicRoughness" => { "baseColorFactor" => hex_rgb(spec[:color]) + [1.0],
                                               "metallicFactor" => 0.0, "roughnessFactor" => spec[:rough] },
                   "doubleSided" => true }
    tris = mesh.tris[name]
    next if tris.empty?

    pos, nrm = [], []
    tris.each do |a, b, c|
      u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]]
      v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]]
      nx, ny, nz = u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]
      l = Math.sqrt(nx * nx + ny * ny + nz * nz)
      l = 1.0 if l.zero?
      [a, b, c].each do |p|
        pos.concat(p)
        nrm.concat([nx / l, ny / l, nz / l])
      end
    end
    count = pos.size / 3
    mins = (0..2).map { |i| pos.each_slice(3).map { _1[i] }.min }
    maxs = (0..2).map { |i| pos.each_slice(3).map { _1[i] }.max }
    [[pos, { "min" => mins, "max" => maxs }], [nrm, {}]].each do |data, extra|
      offset = bin.bytesize
      bin << data.pack("e*")
      views << { "buffer" => 0, "byteOffset" => offset, "byteLength" => data.size * 4, "target" => 34_962 }
      accessors << { "bufferView" => views.size - 1, "componentType" => 5126, "count" => count, "type" => "VEC3" }.merge(extra)
    end
    prims << { "attributes" => { "POSITION" => accessors.size - 2, "NORMAL" => accessors.size - 1 }, "material" => mi }
  end

  gltf = {
    "asset" => { "version" => "2.0", "generator" => "trebuche scripts/ramp_model.rb" },
    "scene" => 0, "scenes" => [{ "nodes" => [0] }],
    "nodes" => [{ "name" => "Seattle Type 422A curb ramp", "mesh" => 0 }],
    "meshes" => [{ "name" => "ramp-422a", "primitives" => prims }],
    "materials" => materials, "accessors" => accessors, "bufferViews" => views,
    "buffers" => [{ "byteLength" => bin.bytesize }],
  }
  json = JSON.generate(gltf)
  json += " " * ((4 - json.bytesize % 4) % 4)
  bin << ("\0" * ((4 - bin.bytesize % 4) % 4))
  total = 12 + 8 + json.bytesize + 8 + bin.bytesize
  [0x46546C67, 2, total].pack("V3") +
    [json.bytesize, 0x4E4F534A].pack("V2") + json +
    [bin.bytesize, 0x004E4942].pack("V2") + bin
end

if $PROGRAM_NAME == __FILE__
  mesh = build
  out = File.expand_path("../docs/ar/ramp-422a.glb", __dir__)
  Dir.mkdir(File.dirname(out)) unless Dir.exist?(File.dirname(out))
  File.binwrite(out, to_glb(mesh))
  ntri = mesh.tris.values.sum(&:size)
  puts "wrote #{out.sub("#{File.expand_path('..', __dir__)}/", '')} (#{File.size(out)} bytes, #{ntri} triangles)"
  if ARGV.include?("--check")
    r = mesh.tris["ramp"].flatten(1)
    w = mesh.tris["warning"].flatten(1)
    puts format("ramp width   %.2f ft", (r.map { _1[0] }.max - r.map { _1[0] }.min) / FT)
    puts format("ramp rise    %.2f in over a %.2f ft run (%.1f%%)", CURB_H / IN, RUN / FT, CURB_H / RUN * 100)
    puts format("wing reach   %.2f ft each (%.1f%%)", WING / FT, CURB_H / WING * 100)
    puts format("landing      %.2f ft deep", LANDING / FT)
    puts format("warning      %.2f ft deep, %d x %d domes", (w.map { _1[2] }.max - w.map { _1[2] }.min) / FT,
                (RAMP_W / DOME_SPACING).floor, (WARN / DOME_SPACING).floor)
  end
end
