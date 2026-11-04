#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes true-scale 3D models of City of Seattle curb ramps as binary glTF,
# for the AR preview page (docs/ar/). One file per ramp type:
#
#   ramp-422a.glb             422a perpendicular ramp with wings (sidewalk at the curb)
#   ramp-422a-side-curbs.glb  422a perpendicular ramp with side curbs (across a planting strip)
#   ramp-422b.glb             422b parallel ramp (two runs along the curb, a lower landing between)
#
# Dimensions follow the 2026 City of Seattle Standard Plans:
#   422a  ramp at least 4'-0" wide (drawn 5'-0"; 5'-0" minimum with side curbs),
#         8.3% max running slope, wings at 10% max, landing at least 4'-0" deep and
#         as wide as the ramp, 4'-0" deep clear area at the bottom
#   422b  ramps 6'-0" wide (5'-0" min) at 8.3% max, lower landing 5'-0" min along the
#         curb at street level, 4'-0" of full-width sidewalk at the top of each run,
#         back curb behind
#   422k  detectable warning 2'-0" deep across the full ramp, truncated domes
#         (base 0.9"-1.4", top 50-65% of base, 0.2" tall, 1.6"-2.4" apart) in an
#         in-line grid aligned with the ramp; side and back curbs 6" wide
# Seattle's standard curb is 6" tall, which sets each run (6'-0" at 8.3%) and the
# wing length along the curb (5'-0" at 10%).
#
# The other 422 types (422c parallel at the corner, 422d/422e directional, 422f
# shared diagonal, 422g blended transition) wrap around the curb radius, which
# differs at every corner, so they aren't modeled.
#
# Units are meters, Y is up, the street side faces +Z, and the origin is on the
# street surface at the curb face, centered on the ramp. Standard library only.
#
#   ruby scripts/ramp_model.rb            # writes every model
#   ruby scripts/ramp_model.rb --check    # also prints dimensions measured from each mesh

require "json"

FT = 0.3048
IN = FT / 12

CURB_H   = 6 * IN                 # 6" curb
RAMP_W   = 5 * FT                 # 5'-0" ramp (422a)
RUN      = CURB_H / 0.083         # 8.3% max running slope -> ~6'-0"
WING     = CURB_H / 0.10          # 10% max wing slope along the curb -> 5'-0"
LANDING  = 4 * FT                 # 4'-0" landing
WARN     = 2 * FT                 # 2'-0" detectable warning
CLEAR    = 4 * FT                 # clear area depth on the street
STUB     = 2 * FT                 # curb/sidewalk shown past each wing, for context
SIDE_C   = 6 * IN                 # side/back curb width (422k)
STRIP    = 4 * FT                 # planting strip shown beside the side-curb ramp
WALK     = 6 * FT                 # sidewalk depth behind a planting strip (6'-0" min)
PAR_W    = 6 * FT                 # 422b ramp width, measured from the curb
PAR_LAND = 5 * FT                 # 422b lower landing along the curb
PAR_TOP  = 4 * FT                 # 422b full-width sidewalk at the top of each run
BACK_GRASS = 2 * FT               # landscape shown behind a back curb
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
  "grass"    => { color: "#6f8f4e", rough: 1.0 },
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

  # Convex planar polygon, wound so its front faces `dir` (whatever order the points are in).
  def face(mat, pts, dir)
    u = sub(pts[1], pts[0])
    v = sub(pts[2], pts[0])
    poly(mat, dot(cross(u, v), dir).negative? ? pts.reverse : pts)
  end

  # Level rectangle at height y.
  def flat(mat, x0, x1, z0, z1, y) = face(mat, [[x0, y, z0], [x1, y, z0], [x1, y, z1], [x0, y, z1]], UP)

  # Box from two corners (for thin strips and slabs).
  def box(mat, (x0, y0, z0), (x1, y1, z1))
    quad(mat, [x0, y1, z1], [x1, y1, z1], [x1, y1, z0], [x0, y1, z0]) # top
    quad(mat, [x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]) # front (+z)
    quad(mat, [x1, y0, z0], [x0, y0, z0], [x0, y1, z0], [x1, y1, z0]) # back
    quad(mat, [x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [x0, y1, z0]) # left
    quad(mat, [x1, y0, z1], [x1, y0, z0], [x1, y1, z0], [x1, y1, z1]) # right
  end

  # Detectable warning panel with truncated domes in an in-line grid. `origin` is
  # the middle of the panel's street-side edge, `across` runs along that edge,
  # `into` runs away from the street along the surface, `n` is the surface normal.
  def warning(origin, across, into, n, width, depth)
    up = scale(n, LIFT)
    at = ->(u, v) { add(add(origin, up), add(scale(across, u), scale(into, v))) }
    hw = width / 2
    face("warning", [at.(-hw, 0), at.(hw, 0), at.(hw, depth), at.(-hw, depth)], n)
    cols = (width / DOME_SPACING).floor
    rows = (depth / DOME_SPACING).floor
    u0 = -(cols - 1) * DOME_SPACING / 2
    v0 = (depth - (rows - 1) * DOME_SPACING) / 2
    seg = 10
    rows.times do |r|
      cols.times do |c|
        base = at.(u0 + c * DOME_SPACING, v0 + r * DOME_SPACING)
        ring = lambda do |radius, lift|
          Array.new(seg) do |i|
            a = 2 * Math::PI * i / seg
            add(add(base, scale(n, lift)), add(scale(across, radius * Math.cos(a)), scale(into, radius * Math.sin(a))))
          end
        end
        b = ring.(DOME_BASE / 2, 0)
        top = ring.(DOME_TOP / 2, DOME_H)
        seg.times do |i|
          j = (i + 1) % seg
          mid = scale(add(add(b[i], b[j]), add(top[i], top[j])), 0.25)
          face("warning", [b[i], b[j], top[j], top[i]], sub(mid, add(base, scale(n, DOME_H / 2))))
        end
        face("warning", top, n)
      end
    end
    @domes = cols * rows
  end

  attr_reader :domes

  # A joint line drawn on a surface between two points.
  def joint(a, b)
    dx, dz = b[0] - a[0], b[2] - a[2]
    l = Math.hypot(dx, dz)
    ox, oz = -dz / l * JOINT_W / 2, dx / l * JOINT_W / 2
    lift = [0, LIFT * 2, 0]
    face("joint", [add([a[0] + ox, a[1], a[2] + oz], lift), add([b[0] + ox, b[1], b[2] + oz], lift),
                   add([b[0] - ox, b[1], b[2] - oz], lift), add([a[0] - ox, a[1], a[2] - oz], lift)], UP)
  end

  # A clear area on the street in front of the ramp, as a dashed white outline:
  # the far edge (parallel to the curb) and both sides (running out from the curb).
  def clear_area(width, depth)
    half = width / 2
    dash, w = 0.15, 0.025
    dashes = ->(from, to) { (from...to).step(dash * 2).map { [_1, [_1 + dash, to].min] } }
    dashes.(-half, half).each { |a, b| box("paint", [a, 0, depth - w / 2], [b, LIFT, depth + w / 2]) }
    [-half, half].each do |x|
      dashes.(0.02, depth).each { |a, b| box("paint", [x - w / 2, 0, a], [x + w / 2, LIFT, b]) }
    end
  end

  # Vertical faces around the outside of the slab, from the street up to height h.
  def slab_edges(x0, x1, z_back, h)
    face("curb", [[x0, 0, z_back], [x0, 0, 0], [x0, h, 0], [x0, h, z_back]], [-1, 0, 0])
    face("curb", [[x1, 0, 0], [x1, 0, z_back], [x1, h, z_back], [x1, h, 0]], [1, 0, 0])
    face("curb", [[x0, 0, z_back], [x1, 0, z_back], [x1, h, z_back], [x0, h, z_back]], [0, 0, -1])
  end
end

UP = [0, 1, 0].freeze
FRONT = [0, 0, 1].freeze

def add(a, b) = a.zip(b).map { _1 + _2 }
def sub(a, b) = a.zip(b).map { _1 - _2 }
def scale(a, s) = a.map { _1 * s }
def dot(a, b) = a.zip(b).sum { _1 * _2 }
def cross(u, v) = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]

# Unit vectors for a run rising from the street at z = 0 toward -z.
def run_frame
  s = CURB_H / RUN
  len = Math.sqrt(1 + s**2)
  [[0, 1 / len, s / len], [0, s / len, -1 / len]] # normal, up-slope
end

# 422a with wings: the sidewalk reaches the curb, so the sides of the run are
# wings sloping down to it along the curb.
def build_422a
  m = Mesh.new
  hw = RAMP_W / 2
  zt = -RUN                 # top of ramp
  zl = -RUN - LANDING       # back of landing
  xs = hw + WING + STUB     # outer edge of the context stubs
  h = CURB_H

  m.quad("ramp", [-hw, 0, 0], [hw, 0, 0], [hw, h, zt], [-hw, h, zt])
  m.tri("wing", [-hw, 0, 0], [-hw, h, zt], [-hw - WING, h, 0])
  m.tri("wing", [hw, 0, 0], [hw + WING, h, 0], [hw, h, zt])
  m.face("curb", [[-hw, 0, 0], [-hw - WING, h, 0], [-hw - WING, 0, 0]], FRONT)
  m.face("curb", [[hw, 0, 0], [hw + WING, 0, 0], [hw + WING, h, 0]], FRONT)
  m.flat("ramp", -hw, hw, zt, zl, h)
  m.face("sidewalk", [[-xs, h, 0], [-hw - WING, h, 0], [-hw, h, zt], [-hw, h, zl], [-xs, h, zl]], UP)
  m.face("sidewalk", [[xs, h, 0], [xs, h, zl], [hw, h, zl], [hw, h, zt], [hw + WING, h, 0]], UP)
  m.face("curb", [[-xs, 0, 0], [-hw - WING, 0, 0], [-hw - WING, h, 0], [-xs, h, 0]], FRONT)
  m.face("curb", [[hw + WING, 0, 0], [xs, 0, 0], [xs, h, 0], [hw + WING, h, 0]], FRONT)
  m.slab_edges(-xs, xs, zl, h)

  n, t = run_frame
  m.warning([0, 0, 0], [1, 0, 0], t, n, RAMP_W, WARN)

  m.joint([-hw - WING, h, 0], [-hw, h, zt])
  m.joint([-hw, h, zt], [hw, h, zt])
  m.joint([hw, h, zt], [hw + WING, h, 0])
  m.joint([-hw, h, zt], [-hw, h, zl])
  m.joint([-hw, h, zl], [hw, h, zl])
  m.joint([hw, h, zl], [hw, h, zt])

  m.clear_area(4 * FT, CLEAR)
  m
end

# 422a with side curbs: the run crosses a planting strip, so 6" curbs hold the
# landscape back on each side instead of wings (ramp 5'-0" minimum).
def build_422a_side_curbs
  m = Mesh.new
  hw = RAMP_W / 2
  hc = hw + SIDE_C            # outer face of each side curb
  xs = hc + STRIP             # outer edge of the planting strip shown
  zt = -RUN                   # top of ramp = back of the planting strip
  zl = zt - LANDING           # back of landing
  zb = zt - WALK              # back of sidewalk
  h = CURB_H

  m.quad("ramp", [-hw, 0, 0], [hw, 0, 0], [hw, h, zt], [-hw, h, zt])
  [-1, 1].each do |sx|
    xi, xo = sx * hw, sx * hc
    # Side curb: level top at sidewalk height, its inner face rising from the run.
    m.flat("curb", [xi, xo].min, [xi, xo].max, 0, zt, h)
    m.face("curb", [[xi, 0, 0], [xi, h, 0], [xi, h, zt]], [-sx, 0, 0])
    m.face("curb", [[xi, 0, 0], [xo, 0, 0], [xo, h, 0], [xi, h, 0]], FRONT)
    # Planting strip beside it, and the street curb under the strip.
    m.flat("grass", [xo, sx * xs].min, [xo, sx * xs].max, 0, zt, h)
    m.face("curb", [[xo, 0, 0], [sx * xs, 0, 0], [sx * xs, h, 0], [xo, h, 0]], FRONT)
    # Sidewalk on either side of the landing.
    m.flat("sidewalk", [xi, sx * xs].min, [xi, sx * xs].max, zt, zb, h)
  end
  m.flat("ramp", -hw, hw, zt, zl, h)
  m.flat("sidewalk", -hw, hw, zl, zb, h)
  m.slab_edges(-xs, xs, zb, h)

  n, t = run_frame
  m.warning([0, 0, 0], [1, 0, 0], t, n, RAMP_W, WARN)

  m.joint([-hw, h, zt], [hw, h, zt])
  m.joint([-hw, h, zt], [-hw, h, zl])
  m.joint([-hw, h, zl], [hw, h, zl])
  m.joint([hw, h, zl], [hw, h, zt])
  m.joint([-xs, h, zt], [-hc, h, zt]) # edge of the sidewalk along the planting strip
  m.joint([hc, h, zt], [xs, h, zt])

  m.clear_area(RAMP_W, CLEAR)
  m
end

# 422b parallel: the sidewalk drops along the curb to a lower landing at street
# level, then rises again, with a back curb behind.
def build_422b
  m = Mesh.new
  lw = PAR_LAND / 2           # half the lower landing
  xr = lw + RUN               # top of each run
  xs = xr + PAR_TOP           # end of the full-width sidewalk at the top
  zb = -PAR_W                 # back of the ramps = inner face of the back curb
  zc = zb - SIDE_C            # outer face of the back curb
  zg = zc - BACK_GRASS        # back of the landscape shown
  h = CURB_H

  m.flat("ramp", -lw, lw, 0, zb, 0)
  [-1, 1].each do |sx|
    a, b = sx * lw, sx * xr
    m.face("ramp", [[a, 0, 0], [a, 0, zb], [b, h, zb], [b, h, 0]], UP)
    m.face("curb", [[a, 0, 0], [b, 0, 0], [b, h, 0]], FRONT)            # curb face under the run
    m.face("curb", [[a, 0, zb], [b, h, zb], [a, h, zb]], FRONT)         # back curb face above the run
    m.flat("sidewalk", [b, sx * xs].min, [b, sx * xs].max, 0, zb, h)
    m.face("curb", [[b, 0, 0], [sx * xs, 0, 0], [sx * xs, h, 0], [b, h, 0]], FRONT)
  end
  m.face("curb", [[-lw, 0, zb], [lw, 0, zb], [lw, h, zb], [-lw, h, zb]], FRONT) # back curb above the landing
  m.flat("curb", -xs, xs, zb, zc, h)
  m.flat("grass", -xs, xs, zc, zg, h)
  m.slab_edges(-xs, xs, zg, h)

  m.warning([0, 0, 0], [1, 0, 0], [0, 0, -1], UP, PAR_LAND, WARN)

  [lw, xr].each do |x|
    m.joint([-x, x == lw ? 0 : h, 0], [-x, x == lw ? 0 : h, zb])
    m.joint([x, x == lw ? 0 : h, 0], [x, x == lw ? 0 : h, zb])
  end
  m
end

MODELS = {
  "ramp-422a.glb" => { name: "Seattle Type 422A curb ramp (wings)", build: :build_422a,
                       width: RAMP_W, run: RUN },
  "ramp-422a-side-curbs.glb" => { name: "Seattle Type 422A curb ramp (side curbs)", build: :build_422a_side_curbs,
                                  width: RAMP_W, run: RUN },
  "ramp-422b.glb" => { name: "Seattle Type 422B parallel curb ramp", build: :build_422b,
                       width: PAR_W, run: RUN },
}.freeze

# ---------------------------------------------------------------- glTF writer

def hex_rgb(hex) = hex.delete("#").scan(/../).map { (_1.to_i(16) / 255.0)**2.2 } # sRGB -> linear

def to_glb(mesh, name, mesh_name)
  bin = +"".b
  views, accessors, prims, materials = [], [], [], []
  MATERIALS.each do |mat, spec|
    tris = mesh.tris[mat]
    next if tris.empty?

    materials << { "name" => mat,
                   "pbrMetallicRoughness" => { "baseColorFactor" => hex_rgb(spec[:color]) + [1.0],
                                               "metallicFactor" => 0.0, "roughnessFactor" => spec[:rough] },
                   "doubleSided" => true }
    mi = materials.size - 1

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
    "nodes" => [{ "name" => name, "mesh" => 0 }],
    "meshes" => [{ "name" => mesh_name, "primitives" => prims }],
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

def extent(pts, axis) = pts.map { _1[axis] }.max - pts.map { _1[axis] }.min

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  dir = File.join(root, "docs/ar")
  Dir.mkdir(dir) unless Dir.exist?(dir)
  MODELS.each do |file, spec|
    mesh = send(spec[:build])
    out = File.join(dir, file)
    File.binwrite(out, to_glb(mesh, spec[:name], File.basename(file, ".glb")))
    ntri = mesh.tris.values.sum(&:size)
    puts "wrote #{out.sub("#{root}/", '')} (#{File.size(out)} bytes, #{ntri} triangles)"
    next unless ARGV.include?("--check")

    r = mesh.tris["ramp"].flatten(1)
    w = mesh.tris["warning"].flatten(1)
    all = mesh.tris.values.flatten(2)
    puts format("  footprint  %.1f ft along the curb, %.1f ft deep, %.2f in tall",
                extent(all, 0) / FT, extent(all, 2) / FT, extent(all, 1) / IN)
    puts format("  concrete   %.2f x %.2f ft (ramp runs and landings)", extent(r, 0) / FT, extent(r, 2) / FT)
    puts format("  each run   rises %.2f in over %.2f ft (%.1f%%), %.2f ft wide",
                CURB_H / IN, spec[:run] / FT, CURB_H / spec[:run] * 100, spec[:width] / FT)
    puts format("  warning    %.2f x %.2f ft (plan), %d domes", extent(w, 0) / FT, extent(w, 2) / FT, mesh.domes)
  end
end
