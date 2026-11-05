#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes a true-scale 3D model of every curb ramp design in
# scripts/ramp_designs.rb as binary glTF, docs/ar/ramp-<id>.glb, for the AR page.
#
# The designs are described the way they're drawn: surfaces in drawing order,
# later ones on top. A model can't stack surfaces like that, so each surface is
# cut wherever a later one covers it in plan, then the vertical faces are added
# (curb faces, side and back curbs, and the slab's cut edges). Warning panels
# get truncated domes at their real size and spacing (422k), and the clear area
# is dashed on the street. Streets and crosswalks are left out: in AR, the
# real street is the floor.
#
# Units are meters, Y is up, the street side faces +Z, and the origin is each
# design's anchor (on the street at the curb, at the ramp or the corner's apex).
#
#   ruby scripts/ramp_model.rb             # writes every model
#   ruby scripts/ramp_model.rb 422g        # just this one
#   ruby scripts/ramp_model.rb --check     # also prints sizes measured from each mesh

require "json"
require_relative "ramp_designs"

FT = 0.3048
IN = 1 / 12.0 # in feet; the designs are in feet

LIFT     = 0.005     # feet: surface details sit this far above the surface
JOINT_W  = 0.04      # feet: drawn width of a joint line
DOME_BASE    = 1.15 * IN
DOME_TOP     = 0.6 * DOME_BASE
DOME_H       = 0.2 * IN
DOME_SPACING = 2.35 * IN
DOME_SEG     = 8

MATERIALS = {
  "ramp"     => { color: "#d9d3c5", rough: 0.92 },
  "wing"     => { color: "#d2ccbd", rough: 0.92 },
  "sidewalk" => { color: "#c8c1b2", rough: 0.95 },
  "curb"     => { color: "#b5ad9b", rough: 0.9 },
  "warning"  => { color: "#f2b51c", rough: 0.6 },  # Federal Safety Yellow (approx.)
  "joint"    => { color: "#6a6354", rough: 1.0 },
  "paint"    => { color: "#f4f1ea", rough: 0.7 },
  "guide"    => { color: "#ffffff", rough: 0.5 },  # where the real curb's edge goes
  "grass"    => { color: "#6f8f4e", rough: 1.0 },
}.freeze

# Surfaces that stand for what's already at the corner. The illustrations draw
# them for context; in AR they'd only hide the real ground, so they're left out.
AR_CONTEXT = %i[grass walk].freeze

SURFACE_MATERIAL = { grass: "grass", walk: "sidewalk", landing: "ramp", ramp: "ramp", flush: "ramp",
                     wing: "wing", curbtop: "curb" }.freeze

# Geometry in design coordinates (feet, [x, z, h]); converted on write.
class Mesh
  attr_reader :tris, :smooth
  attr_accessor :anchor

  def initialize
    @tris = Hash.new { |hash, k| hash[k] = [] }
    @smooth = Hash.new { |hash, k| hash[k] = { pos: [], nrm: [], idx: [] } }
  end

  def tri(mat, a, b, c) = @tris[mat] << [a, b, c]
  def fan(mat, pts) = (1...pts.size - 1).each { |i| tri(mat, pts[0], pts[i], pts[i + 1]) }
end

# ---------------------------------------------------------------- plan geometry

EPS = 1e-7

def cross2(o, a, b) = (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
def area2(pts) = pts.each_with_index.sum { |p, i| q = pts[(i + 1) % pts.size]; p[0] * q[1] - q[0] * p[1] } / 2.0
def lerp(a, b, t) = a.zip(b).map { _1 + (_2 - _1) * t }

def clean(pts)
  out = []
  pts.each { |p| out << p unless out.any? && dist(out.last, p) < 1e-6 }
  out.pop while out.size > 1 && dist(out.first, out.last) < 1e-6
  out
end

# Keeps the part of a polygon on the left of the line a -> b (Sutherland-Hodgman).
def clip(poly, a, b)
  out = []
  poly.each_with_index do |p, i|
    q = poly[(i + 1) % poly.size]
    dp, dq = cross2(a, b, p), cross2(a, b, q)
    out << p if dp >= -EPS
    out << lerp(p, q, dp.to_f / (dp - dq)) if (dp >= -EPS) != (dq >= -EPS)
  end
  clean(out)
end

def clip_box(poly, (x0, x1, z0, z1))
  box = [[x0, z0], [x1, z0], [x1, z1], [x0, z1]]
  box.each_with_index { |a, i| poly = clip(poly, a, box[(i + 1) % 4]) if poly.size >= 3 }
  poly
end

# Ear clipping, for simple polygons in plan; returns counter-clockwise triangles.
def triangulate(pts)
  pts = clean(pts)
  return [] if pts.size < 3 || area2(pts).abs < 1e-9

  pts = pts.reverse if area2(pts).negative?
  idx = (0...pts.size).to_a
  tris = []
  while idx.size > 3
    n = idx.size
    ear = (0...n).find do |i|
      a, b, c = pts[idx[i - 1]], pts[idx[i]], pts[idx[(i + 1) % n]]
      next false unless cross2(a, b, c) > 1e-12

      idx.none? do |j|
        q = pts[j]
        next false if [a, b, c].include?(q)

        cross2(a, b, q) >= -1e-12 && cross2(b, c, q) >= -1e-12 && cross2(c, a, q) >= -1e-12
      end
    end
    ear ||= (0...n).min_by { |i| cross2(pts[idx[i - 1]], pts[idx[i]], pts[idx[(i + 1) % n]]).abs }
    tris << [pts[idx[ear - 1]], pts[idx[ear]], pts[idx[(ear + 1) % n]]]
    idx.delete_at(ear)
  end
  tris << idx.map { pts[_1] }
  tris.select { cross2(*_1) > 1e-10 }
end

# A convex polygon minus a counter-clockwise triangle, as convex pieces.
def subtract(poly, tri)
  pieces = []
  rest = poly
  3.times do |i|
    a, b = tri[i], tri[(i + 1) % 3]
    outside = clip(rest, b, a)
    pieces << outside if outside.size >= 3 && area2(outside).abs > 1e-7
    rest = clip(rest, a, b)
    break if rest.size < 3
  end
  pieces
end

# The part of segment a-b inside the bounds (Liang-Barsky), or nil.
def clip_segment(a, b, (x0, x1, z0, z1))
  t0, t1 = 0.0, 1.0
  dx, dz = b[0] - a[0], b[1] - a[1]
  [[-dx, a[0] - x0], [dx, x1 - a[0]], [-dz, a[1] - z0], [dz, z1 - a[1]]].each do |pp, q|
    if pp.abs < 1e-12
      return nil if q.negative?
    else
      t = q / pp
      pp.negative? ? t0 = [t0, t].max : t1 = [t1, t].min
    end
  end
  t0 < t1 ? [lerp(a, b, t0), lerp(a, b, t1)] : nil
end

def bbox(pts) = [pts.map { _1[0] }.minmax, pts.map { _1[1] }.minmax]

def overlap?((ax, az), (bx, bz)) = ax[0] < bx[1] - EPS && bx[0] < ax[1] - EPS && az[0] < bz[1] - EPS && bz[0] < az[1] - EPS

# ---------------------------------------------------------------- 3D details

def norm3(v) = mul(v, 1 / Math.sqrt(v.sum { _1 * _1 }))
def cross3(u, v) = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]

# Upward unit normal of a surface given by at(u, v), in [x, z, h].
def surface_frame(at, u, v)
  e = 0.01
  du = sub(at.(u + e, v), at.(u - e, v))
  dv = sub(at.(u, v + e), at.(u, v - e))
  n = norm3(cross3(du, dv))
  n = mul(n, -1) if n[2].negative?
  [norm3(du), norm3(dv), n]
end

def add_warning(mesh, length, depth, at)
  nu = [(length / 0.5).ceil, 1].max
  grid = (0..nu).map do |i|
    (0..2).map do |j|
      u, v = length * i / nu, depth * j / 2
      add(at.(u, v), mul(surface_frame(at, u, v)[2], LIFT * 1.6))
    end
  end
  nu.times do |i|
    2.times { |j| up_quad(mesh, "warning", grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]) }
  end
  cols, rows = (length / DOME_SPACING).floor, (depth / DOME_SPACING).floor
  u0, v0 = (length - (cols - 1) * DOME_SPACING) / 2, (depth - (rows - 1) * DOME_SPACING) / 2
  sm = mesh.smooth["warning"]
  rows.times do |r|
    cols.times do |c|
      u, v = u0 + c * DOME_SPACING, v0 + r * DOME_SPACING
      across, into, n = surface_frame(at, u, v)
      into = norm3(cross3(n, across))
      base = add(at.(u, v), mul(n, LIFT * 1.6))
      first = sm[:pos].size / 3
      [[DOME_BASE / 2, 0], [DOME_TOP / 2, DOME_H]].each do |rad, lift|
        DOME_SEG.times do |i|
          a = 2 * Math::PI * i / DOME_SEG
          out = add(mul(across, Math.cos(a)), mul(into, Math.sin(a)))
          sm[:pos].concat(add(add(base, mul(n, lift)), mul(out, rad)))
          sm[:nrm].concat(norm3(add(out, mul(n, lift.zero? ? 0.4 : 1.2))))
        end
      end
      sm[:pos].concat(add(base, mul(n, DOME_H)))
      sm[:nrm].concat(n)
      top = first + 2 * DOME_SEG
      DOME_SEG.times do |i|
        j = (i + 1) % DOME_SEG
        b0, b1, t0, t1 = first + i, first + j, first + DOME_SEG + i, first + DOME_SEG + j
        sm[:idx].concat([b0, b1, t1, b0, t1, t0, t0, t1, top])
      end
    end
  end
  cols * rows
end

# A quad wound so it faces up.
def up_quad(mesh, mat, a, b, c, d)
  pts = [a, b, c, d]
  pts = pts.reverse if area2(pts).negative?
  mesh.fan(mat, pts)
end

# A thin strip along a line on the surfaces (joints, painted dashes).
def strip(mesh, mat, a, b, width, lift)
  d = [b[0] - a[0], b[1] - a[1]]
  l = Math.hypot(*d)
  return if l < 1e-6

  o = [-d[1] / l * width / 2, d[0] / l * width / 2, 0]
  up = [0, 0, lift]
  up_quad(mesh, mat, add(add(a, o), up), add(add(b, o), up), add(sub(b, o), up), add(sub(a, o), up))
end

def build(design)
  mesh = Mesh.new
  bnd = design[:bounds]
  surfaces = []
  domes = 0
  design_scene(design).ops.each do |kind, args, kw, blk|
    case kind
    when :surface
      next if AR_CONTEXT.include?(kw[:kind]) # already there in the street: leave it to the camera

      tris = triangulate(args[0]).map { clip_box(_1, bnd) }.select { _1.size >= 3 }
      surfaces << { mat: SURFACE_MATERIAL.fetch(kw[:kind]), pieces: tris, tris: tris.flat_map { triangulate(_1) } }
    when :wall
      next if kw[:context]

      poly = clip_box(args[0], bnd)
      mesh.fan("curb", poly) if poly.size >= 3
    when :curb
      # Only the curb the ramp lowers is new; elsewhere, a thin line marks
      # where the real curb's top edge should line up.
      pts = args[0].walk(0, args[0].length, 0.3)
      pts.each_cons(2) do |a, b|
        if a[2] > CH - 1e-3 && b[2] > CH - 1e-3
          (seg = clip_segment(a, b, bnd)) && strip(mesh, "guide", *seg, 0.12, LIFT)
        elsif a[2] > 1e-4 || b[2] > 1e-4
          q = clip_box([[a[0], a[1], 0], [b[0], b[1], 0], b, a], bnd)
          mesh.fan("curb", q) if q.size >= 3
        end
      end
    when :warning
      domes += add_warning(mesh, args[0], args[1] || 2.0, blk)
    when :joint
      args.each_cons(2) { |a, b| (seg = clip_segment(a, b, bnd)) && strip(mesh, "joint", *seg, JOINT_W, LIFT * 2) }
    when :clear
      pts = args[0]
      pts.each_with_index do |a, i|
        b = pts[(i + 1) % pts.size]
        l = dist(a, b)
        t = 0.0
        while t < l
          strip(mesh, "paint", lerp(a, b, t / l), lerp(a, b, [t + 0.5, l].min / l), 0.08, LIFT)
          t += 1.0
        end
      end
    end
  end

  # Each surface loses whatever a later one covers.
  surfaces.each_with_index do |s, i|
    pieces = s[:pieces]
    surfaces[(i + 1)..].each do |later|
      later[:tris].each do |t|
        tb = bbox(t)
        pieces = pieces.flat_map { |p| overlap?(bbox(p), tb) ? subtract(p, t) : [p] }
      end
    end
    pieces.each do |p|
      p = p.reverse if area2(p).negative?
      mesh.fan(s[:mat], p)
      # the slab's cut edge where the model ends
      p.each_with_index do |a, k|
        b = p[(k + 1) % p.size]
        next if a[2] < 1e-4 && b[2] < 1e-4

        on_edge = [[0, bnd[0]], [0, bnd[1]], [1, bnd[2]], [1, bnd[3]]].any? { |ax, v| (a[ax] - v).abs < 1e-6 && (b[ax] - v).abs < 1e-6 }
        mesh.fan("curb", [[a[0], a[1], 0], [b[0], b[1], 0], b, a]) if on_edge
      end
    end
  end
  [mesh, domes]
end

def to_gl(p, anchor) = [(p[0] - anchor[0]) * FT, p[2] * FT, -(p[1] - anchor[1]) * FT]

# ---------------------------------------------------------------- glTF writer

def hex_rgb(hex) = hex.delete("#").scan(/../).map { (_1.to_i(16) / 255.0)**2.2 } # sRGB -> linear

def to_glb(mesh, name, mesh_name)
  bin = +"".b
  views, accessors, prims, materials = [], [], [], []
  buffer = lambda do |data, fmt, bytes, target|
    offset = bin.bytesize
    bin << data.pack(fmt)
    bin << ("\0" * ((4 - bin.bytesize % 4) % 4))
    views << { "buffer" => 0, "byteOffset" => offset, "byteLength" => data.size * bytes, "target" => target }
    views.size - 1
  end
  vec3 = lambda do |data, extra = {}|
    accessors << { "bufferView" => buffer.(data, "e*", 4, 34_962), "componentType" => 5126,
                   "count" => data.size / 3, "type" => "VEC3" }.merge(extra)
    accessors.size - 1
  end
  bounds = ->(pos) { { "min" => (0..2).map { |i| pos.each_slice(3).map { _1[i] }.min }, "max" => (0..2).map { |i| pos.each_slice(3).map { _1[i] }.max } } }
  MATERIALS.each do |mat, spec|
    tris = mesh.tris[mat]
    smooth = mesh.smooth[mat]
    next if tris.empty? && smooth[:idx].empty?

    materials << { "name" => mat,
                   "pbrMetallicRoughness" => { "baseColorFactor" => hex_rgb(spec[:color]) + [1.0],
                                               "metallicFactor" => 0.0, "roughnessFactor" => spec[:rough] },
                   "doubleSided" => true }
    mi = materials.size - 1

    pos, nrm = [], []
    tris.map { |t| t.map { to_gl(_1, mesh.anchor) } }.each do |a, b, c|
      u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]]
      v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]]
      nx, ny, nz = u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]
      l = Math.sqrt(nx * nx + ny * ny + nz * nz)
      next if l < 1e-12 # zero-area sliver
      [a, b, c].each do |p|
        pos.concat(p)
        nrm.concat([nx / l, ny / l, nz / l])
      end
    end
    unless pos.empty?
      pa = vec3.(pos, bounds.(pos))
      prims << { "attributes" => { "POSITION" => pa, "NORMAL" => vec3.(nrm) }, "material" => mi }
    end
    next if smooth[:idx].empty?

    # Smooth-shaded, indexed geometry (the domes).
    spos = smooth[:pos].each_slice(3).flat_map { to_gl(_1, mesh.anchor) }
    snrm = smooth[:nrm].each_slice(3).flat_map { |x, z, h| [x, h, -z] }
    pa = vec3.(spos, bounds.(spos))
    na = vec3.(snrm)
    wide = smooth[:pos].size / 3 > 65_535
    accessors << { "bufferView" => buffer.(smooth[:idx], wide ? "V*" : "v*", wide ? 4 : 2, 34_963),
                   "componentType" => wide ? 5125 : 5123, "count" => smooth[:idx].size, "type" => "SCALAR" }
    prims << { "attributes" => { "POSITION" => pa, "NORMAL" => na }, "indices" => accessors.size - 1, "material" => mi }
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
  total = 12 + 8 + json.bytesize + 8 + bin.bytesize
  [0x46546C67, 2, total].pack("V3") +
    [json.bytesize, 0x4E4F534A].pack("V2") + json +
    [bin.bytesize, 0x004E4942].pack("V2") + bin
end

def extent(pts, axis) = pts.map { _1[axis] }.max - pts.map { _1[axis] }.min

if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  only = ARGV.reject { _1.start_with?("-") }
  DESIGNS.each do |d|
    next unless only.empty? || only.include?(d[:id])

    mesh, domes = build(d)
    mesh.anchor = d[:anchor]
    out = File.join(root, "docs/ar/ramp-#{d[:id]}.glb")
    File.binwrite(out, to_glb(mesh, "Seattle Type #{d[:id][0, 4].upcase}: #{d[:name]}", "ramp-#{d[:id]}"))
    ntri = mesh.tris.values.sum(&:size) + mesh.smooth.values.sum { _1[:idx].size / 3 }
    puts format("wrote docs/ar/ramp-%s.glb (%d KB, %d triangles)", d[:id], File.size(out) / 1024, ntri)
    next unless ARGV.include?("--check")

    all = mesh.tris.values.flatten(2)
    puts format("  footprint %.1f x %.1f ft, %.2f in tall, %d domes",
                extent(all, 0), extent(all, 1), extent(all, 2) / IN, domes)
  end
end
