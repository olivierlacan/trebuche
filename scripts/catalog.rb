#!/usr/bin/env ruby
# frozen_string_literal: true

# Draws the curb ramp design catalog: one illustration per City of Seattle curb
# ramp type, in the style of the logo (scripts/logo.rb): seen from above at a
# slight angle, warm concrete, yellow truncated-dome panels, recessed joints,
# ladder crosswalks, grass, and a fine grain.
#
# Every drawing is to scale in plan (feet), from the 2026 City of Seattle
# Standard Plans for Municipal Construction. Like the logo, curb height is drawn
# about 2.6 times taller than it is so the 6" curb reads at small sizes.
#   420   sidewalk scoring in 2' squares
#   422a  perpendicular ramp: 5'-0" wide, 8.3% (6'-0" run for a 6" curb), wings at
#         10%, 4'-0" landing, 4'-0" clear area; side curbs instead of wings across
#         a planting strip (ramp 5'-0" min)
#   422b  parallel ramp: 6'-0" wide runs at 8.3%, 5'-0" lower landing at street
#         level, 4'-0" of full-width sidewalk at the top of each run, back curb
#   422c  parallel ramps at the corner: the lower landing wraps the curb return,
#         back curb behind it, warning panels (radial tile) at each crossing
#   422d  directional ramp: run parallel to the crosswalk, bottom 5'-0" or less
#         from the curb, warning panel at the bottom of the run, 4'-0" clear area
#   422e  directional ramp set back more than 5'-0": warning panel moves to the
#         back of curb (radial tile)
#   422f  shared diagonal ramp: at the apex, warning panel within 8" of the curb,
#         5'-0" x 4'-0" clear area inside the lines of both curbs extended
#   422g  blended transition: the corner slopes at 5% max down to the street,
#         radial warning panel along the whole curb, level bypass behind
#   422h  island cut-through: street-level path through an island, two 2'-0"
#         warning panels at least 2'-0" apart, 5'-0" wide
#   422k  warning panels 2'-0" deep, Federal Safety Yellow; side/back curbs 6" wide
#   712   ladder crosswalk: pairs of 8" bars with an 8" gap, 10' long, 5' apart
#
#   ruby scripts/catalog.rb    # writes docs/seattle/curb-ramps/<type>.svg

ROOT = File.expand_path("..", __dir__)
OUT = File.join(ROOT, "docs/seattle/curb-ramps")

CH   = 0.5    # 6" curb, in feet
LIFT = 2.6    # drawn height exaggeration (the logo draws its curb about 3x)
K    = 0.68   # foreshortening of depth, as in the logo
VW, VH = 160.0, 100.0

def add(a, b) = a.zip(b).map { _1 + _2 }
def sub(a, b) = a.zip(b).map { _1 - _2 }
def mul(a, s) = a.map { _1 * s }
def dist(a, b) = Math.hypot(a[0] - b[0], a[1] - b[1])
def unit(a) = mul(a, 1 / Math.hypot(*a))
def f2(v) = format("%.2f", v)

# A curb line in plan, walked from the bottom street (left) toward the right
# street, so the sidewalk is always on the left. Heights along it are 6" except
# where a ramp lowers it.
class Curb
  attr_reader :pts

  def initialize(pts)
    @pts = pts
    @cum = [0.0]
    pts.each_cons(2) { |a, b| @cum << @cum.last + dist(a, b) }
    @dips = []
  end

  def self.straight = new([[-200.0, 0.0], [200.0, 0.0]])

  # Straight curb along z = 0, a radius-r return, then straight along x = 0.
  def self.corner(r)
    arc = (0..90).step(2).map { |deg| a = (deg - 90) * Math::PI / 180; [-r + r * Math.cos(a), r + r * Math.sin(a)] }
    new([[-200.0, 0.0]] + arc + [[0.0, 200.0]])
  end

  def length = @cum.last

  def at(s)
    s = s.clamp(0, length)
    i = (@cum.bsearch_index { _1 > s } || @cum.size - 1) - 1
    i = i.clamp(0, @pts.size - 2)
    seg = @cum[i + 1] - @cum[i]
    t = seg.zero? ? 0 : (s - @cum[i]) / seg
    add(@pts[i], mul(sub(@pts[i + 1], @pts[i]), t))
  end

  # Unit vector pointing into the sidewalk at s.
  def inward(s)
    a, b = at(s - 0.05), at(s + 0.05)
    t = unit(sub(b, a))
    [-t[1], t[0]]
  end

  # Arc length where the ray o + t*d (t >= 0) first meets the curb.
  def hit(o, d)
    best = nil
    @pts.each_cons(2).with_index do |(a, b), i|
      e = sub(b, a)
      den = d[0] * e[1] - d[1] * e[0]
      next if den.abs < 1e-12

      w = sub(a, o)
      t = (w[0] * e[1] - w[1] * e[0]) / den
      u = (w[0] * d[1] - w[1] * d[0]) / den
      next unless t >= -1e-6 && u >= -1e-9 && u <= 1 + 1e-9

      best = [t, @cum[i] + u * (@cum[i + 1] - @cum[i])] if best.nil? || t < best[0]
    end
    best&.last or raise "ray misses the curb"
  end

  # Flush with the street from s = a to b, rising back to 6" over la before and lb after.
  def dip(a, b, la, lb) = @dips << [[a, b].min, [a, b].max, la, lb]

  def h(s)
    @dips.map do |a, b, la, lb|
      if s < a then la.positive? && s > a - la ? CH * (a - s) / la : CH
      elsif s <= b then 0.0
      else lb.positive? && s < b + lb ? CH * (s - b) / lb : CH
      end
    end.push(CH).min
  end

  # Points [x, z, h] along the curb from s0 to s1 (either direction).
  def walk(s0, s1, step = 0.4, height: nil)
    n = [((s1 - s0).abs / step).ceil, 1].max
    (0..n).map do |i|
      s = s0 + (s1 - s0) * i / n
      p = at(s)
      [p[0], p[1], height || h(s)]
    end
  end
end

class Art
  CONCRETE = "url(#top)"
  RAMP = "#e2dbca"

  def initialize(center:, scale:, label:)
    @c, @s, @label = center, scale, label
    @o = []
    @flat = [] # level concrete, for the scoring grid
  end

  attr_reader :s

  def pr(x, z, h = 0) = [VW / 2 + (x - @c[0]) * @s, VH / 2 - (z - @c[1]) * @s * K - h * LIFT * @s]
  def pt(p) = pr(*p).map { f2(_1) }.join(" ")
  def path(pts, close: true) = "M#{pts.map { pt(_1) }.join('L')}#{'Z' if close}"
  def raw(svg) = @o << svg

  def fill(pts, color, extra = "") = @o << %(<path d="#{path(pts)}" fill="#{color}"#{extra}/>)

  def concrete(pts)
    @flat << pts
    fill(pts, CONCRETE)
  end

  def grass(pts) = fill(pts, "url(#grass)")
  def street = @o << %(<rect width="#{VW}" height="#{VH}" fill="url(#street)"/>)

  # A sloped (or level) concrete surface, lit from the upper left like the logo:
  # surfaces falling toward the light are lighter, by up to about 8% at 8.3%.
  def surface(pts, base = RAMP, seam: false)
    nx = nz = nh = 0.0
    pts.each_with_index do |a, i|
      b = pts[(i + 1) % pts.size]
      nx += (a[1] - b[1]) * (a[2] + b[2])
      nz += (a[2] - b[2]) * (a[0] + b[0])
      nh += (a[0] - b[0]) * (a[1] + b[1])
    end
    f = 1.0
    if nh.abs > 1e-9
      down = [nx / nh, nz / nh] # downhill direction, scaled by the slope
      f += 0.95 * (down[0] * -0.8 + down[1] * 0.35)
    end
    rgb = base.delete("#").scan(/../).map { (_1.to_i(16) * f.clamp(0.86, 1.1)).round.clamp(0, 255) }
    color = format("#%02x%02x%02x", *rgb)
    fill(pts, color, seam ? %( stroke="#{color}" stroke-width="0.35" stroke-linejoin="round") : "")
  end

  # Heavy broom finish: faint lines, each [[x, z, h], [x, z, h]].
  def brush(lines)
    d = lines.map { |a, b| "M#{pt(a)}L#{pt(b)}" }.join
    @o << %(<path d="#{d}" stroke="#000" stroke-opacity="0.11" stroke-width="#{f2(@s * 0.06)}"/>)
  end

  # Vertical faces along the curb, from the street up to the curb's height.
  def curb_faces(curb, s0 = 0, s1 = curb.length)
    top = curb.walk(s0, s1, 0.3)
    bottom = top.map { |x, z, _| [x, z, 0] }.reverse
    fill(top + bottom, "#a89e88")
    @o << %(<path d="#{path(bottom, close: false)}" fill="none" stroke="#000" stroke-opacity="0.35" stroke-width="#{f2(@s * 0.25)}"/>)
  end

  # The curb's rounded edge catches the light wherever it stands above the street.
  def curb_edge(curb, s0 = 0, s1 = curb.length)
    pts = curb.walk(s0, s1, 0.3)
    runs = pts.slice_when { |a, b| (a[2] > 0.08) != (b[2] > 0.08) }.select { _1.first[2] > 0.08 }
    runs.each do |r|
      @o << %(<path d="#{path(r, close: false)}" fill="none" stroke="#fffdf6" stroke-width="#{f2(@s * 0.14)}" stroke-linejoin="round"/>)
    end
  end

  # A face of a side or back curb (vertical, from the lower surface up to 6").
  def face(pts) = fill(pts, "#b9af99")

  # Recessed joint: dark groove with a light lower lip.
  def joint(*pts, op: 0.75)
    d = path(pts, close: false)
    w = @s * 0.16
    @o << %(<path d="#{d}" fill="none" stroke="#6f6857" stroke-opacity="#{op}" stroke-width="#{f2(w)}" stroke-linejoin="round" stroke-linecap="round"/>)
    @o << %(<path d="#{d}" fill="none" stroke="#fffaf0" stroke-opacity="#{op * 0.8}" stroke-width="#{f2(w * 0.4)}" transform="translate(0 #{f2(w * 0.75)})"/>)
  end

  def faint(*pts) = @o << %(<path d="#{path(pts, close: false)}" fill="none" stroke="#fffdf6" stroke-opacity="0.35" stroke-width="#{f2(@s * 0.08)}" stroke-dasharray="#{f2(@s * 0.5)} #{f2(@s * 0.4)}"/>)

  # Dashed white outline of a clear area on the street.
  def clear_area(pts)
    @o << %(<path d="#{path(pts)}" fill="none" stroke="#f4f1ea" stroke-opacity="0.9" stroke-width="#{f2(@s * 0.12)}" stroke-dasharray="#{f2(@s * 0.55)} #{f2(@s * 0.4)}"/>)
  end

  # Detectable warning panel: `at(u, v)` maps panel coordinates (feet along the
  # curb or ramp, feet of depth) to [x, z, h]; domes in an in-line grid.
  def warning(length, depth = 2.0, &at)
    edge = (0..12).map { at.(length * _1 / 12.0, 0) } + (0..12).map { at.(length * (12 - _1) / 12.0, depth) }
    fill(edge, "url(#panel)")
    sp = 0.62
    cols = [(length / sp).floor, 1].max
    rows = [(depth / sp).floor, 1].max
    rx = @s * 0.2
    domes, hi = [], []
    rows.times do |r|
      v = depth * (r + 0.5) / rows
      cols.times do |c|
        x, y = pr(*at.(length * (c + 0.5) / cols, v))
        domes << %(<ellipse cx="#{f2(x)}" cy="#{f2(y)}" rx="#{f2(rx)}" ry="#{f2(rx * 0.75)}"/>)
        hi << %(<circle cx="#{f2(x - rx * 0.3)}" cy="#{f2(y - rx * 0.28)}" r="#{f2(rx * 0.3)}"/>)
      end
    end
    @o << %(<g fill="#c99a1b">#{domes.join}</g>)
    @o << %(<g fill="#fff6d6" fill-opacity="0.85">#{hi.join}</g>)
  end

  # Std Plan 712 ladder crosswalk: pairs of 8" bars, 8" gap, 10' long, 5' apart.
  # `along` is the direction of the bars (parallel to the curb being crossed),
  # `out` points away from that curb into the street.
  def crosswalk(center, along, out, from: 2.0, to: 40.0)
    bar = 8 / 12.0
    half = 5.0
    zc = from
    rects = []
    while zc < to
      [-bar - bar / 2, bar / 2].each do |o0|
        a = add(center, mul(out, zc + o0))
        b = add(a, mul(out, bar))
        rects << [add(a, mul(along, -half)), add(a, mul(along, half)), add(b, mul(along, half)), add(b, mul(along, -half))]
      end
      zc += 5.0
    end
    @o << %(<g fill="#f2efe6" fill-opacity="0.9">#{rects.map { |r| %(<path d="#{path(r.map { [_1[0], _1[1], 0] })}"/>) }.join}</g>)
  end

  def to_svg(title)
    grid = []
    (-60..60).step(2) do |v|
      grid << path([[v, -60, CH], [v, 80, CH]], close: false)
      grid << path([[-80, v, CH], [80, v, CH]], close: false)
    end
    clip = @flat.map { path(_1) }.join
    <<~SVG
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{VW.to_i} #{VH.to_i}" role="img" aria-label="#{title}">
      <!-- Generated by scripts/catalog.rb: #{@label}, after the 2026 City of Seattle Standard Plans. -->
      <defs>
      <clipPath id="card"><rect width="#{VW.to_i}" height="#{VH.to_i}" rx="7"/></clipPath>
      <clipPath id="flat"><path d="#{clip}"/></clipPath>
      <linearGradient id="top" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="50" y2="#{VH.to_i}">
        <stop offset="0" stop-color="#f3eee3"/><stop offset="1" stop-color="#dcd4c2"/></linearGradient>
      <linearGradient id="street" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#3f4846"/><stop offset="1" stop-color="#2c3332"/></linearGradient>
      <linearGradient id="panel" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#f7cf4d"/><stop offset="1" stop-color="#e9b62a"/></linearGradient>
      <linearGradient id="grass" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="0" y2="#{VH.to_i}">
        <stop offset="0" stop-color="#5e8f45"/><stop offset="1" stop-color="#7aa957"/></linearGradient>
      <radialGradient id="vignette" cx="0.45" cy="0.35" r="0.85">
        <stop offset="0.6" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.22"/></radialGradient>
      <filter id="grain" x="0" y="0" width="100%" height="100%">
        <feTurbulence type="fractalNoise" baseFrequency="1.6" numOctaves="2" seed="4" result="n"/>
        <feColorMatrix in="n" type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -0.9 0.62" result="a"/>
        <feComposite in="a" in2="SourceGraphic" operator="in"/>
      </filter>
      </defs>
      <g clip-path="url(#card)">
      #{@o.first}
      #{@o[1..].join("\n")}
      <path clip-path="url(#flat)" d="#{grid.join}" fill="none" stroke="#7d7564" stroke-opacity="0.13" stroke-width="#{f2(@s * 0.07)}"/>
      <rect width="#{VW.to_i}" height="#{VH.to_i}" filter="url(#grain)" fill="#000" opacity="0.10"/>
      <rect width="#{VW.to_i}" height="#{VH.to_i}" fill="url(#vignette)"/>
      </g>
      <rect x="0.4" y="0.4" width="#{VW - 0.8}" height="#{VH - 0.8}" rx="6.7" fill="none" stroke="#fff" stroke-opacity="0.18" stroke-width="0.8"/>
      </svg>
    SVG
  end
end

# The scoring grid is drawn after everything, so ramps must not be in @flat:
# Art#concrete is only for level sidewalk at curb height.

# ------------------------------------------------------------------ ramps

# A perpendicular or directional ramp. `bc` is the middle of its lower grade
# break, `d` points up the run. Wings slope from the top of the run down to the
# curb, `wings` feet along the curb on each side. `warn` places the 2' panel:
# :ramp (on the run, at the curb), :bottom (at the foot of the run, on the
# flush area), :curb (along the back of curb, radial tile).
def ramp(art, curb, bc, d, w: 5.0, run: 6.0, landing: 4.0, wings: [5.0, 5.0], warn: :ramp, clear: [4.0, 4.0])
  n = [d[1], -d[0]]
  bl, br = add(bc, mul(n, -w / 2)), add(bc, mul(n, w / 2))
  tl, tr = add(bl, mul(d, run)), add(br, mul(d, run))
  ll, lr = add(tl, mul(d, landing)), add(tr, mul(d, landing))
  back = mul(d, -1)
  sl, sr = curb.hit(bl, back), curb.hit(br, back)
  setback = dist(bl, curb.at(sl))
  curb.dip(sl, sr, wings[0], wings[1])

  e = ->(p, h) { [p[0], p[1], h] }
  art.surface(curb.walk(sl, sr, 0.3, height: 0) + [e[br, 0], e[bl, 0]]) if setback > 0.05 || dist(br, curb.at(sr)) > 0.05
  art.surface([e[bl, 0], e[br, 0], e[tr, CH], e[tl, CH]])
  art.surface([e[tl, CH]] + curb.walk(sl - wings[0], sl) + [e[bl, 0]])
  art.surface([e[tr, CH], e[br, 0]] + curb.walk(sr, sr + wings[1]))
  art.fill([e[tl, CH], e[tr, CH], e[lr, CH], e[ll, CH]], Art::CONCRETE)
  art.brush((1..(run / 0.35).floor - 1).map { |i| v = i * 0.35; [e[add(bl, mul(d, v)), CH * v / run], e[add(br, mul(d, v)), CH * v / run]] })

  # clear area: from the lower grade break, toward the street
  if clear
    cw, cd = clear[0] / 2, clear[1]
    art.clear_area([mul(n, -cw), mul(n, cw), add(mul(n, cw), mul(back, cd)), add(mul(n, -cw), mul(back, cd))]
                     .map { e[add(bc, _1), 0] })
  end

  case warn
  when :ramp
    art.warning(w) { |u, v| p = add(add(bl, mul(n, u)), mul(d, v)); e[p, CH * v / run] }
  when :bottom
    art.warning(w) { |u, v| p = add(add(bl, mul(n, u)), mul(d, v - 2.0)); e[p, 0] }
  when :curb
    art.warning(sr - sl) { |u, v| s = sl + u; p = add(curb.at(s), mul(curb.inward(s), v + 0.1)); e[p, 0] }
  end

  ws = curb.at(sl - wings[0])
  we = curb.at(sr + wings[1])
  art.joint(e[ws, CH], e[tl, CH], e[tr, CH], e[we, CH])
  art.joint(e[tl, CH], e[ll, CH], e[lr, CH], e[tr, CH])
end

# ------------------------------------------------------------------ scenes

# Ground for a straight curb along z = 0: sidewalk to `walk` feet (or a planting
# strip first), then grass.
def straight_ground(art, curb, strip: 0.0, walk: 12.0)
  art.street
  yield if block_given?
  art.curb_faces(curb)
  art.grass([[-80, 0, CH], [80, 0, CH], [80, 80, CH], [-80, 80, CH]])
  art.concrete([[-80, strip, CH], [80, strip, CH], [80, strip + walk, CH], [-80, strip + walk, CH]])
  art.raw(%(<path d="#{art.path([[-80, strip + walk, CH], [80, strip + walk, CH]], close: false)}" stroke="#fffdf6" stroke-opacity="0.7" stroke-width="#{f2(art.s * 0.1)}"/>))
end

def scene_422a
  art = Art.new(center: [0, 5.5], scale: 4.6, label: "Type 422A perpendicular curb ramp with wings")
  curb = Curb.straight
  # wings change the curb before it's drawn, so measure them first
  curb.dip(curb.hit([-2.5, 0], [0, -1]), curb.hit([2.5, 0], [0, -1]), 5, 5)
  straight_ground(art, curb, walk: 10.0) { art.crosswalk([0, 0], [1, 0], [0, -1]) }
  [-11.5, 11.5].each { |x| art.joint([x, 0, CH], [x, 10, CH], op: 0.5) } # contraction joints
  ramp(art, curb, [0, 0], [0, 1], clear: [4.0, 4.0])
  art.curb_edge(curb)
  art
end

def scene_422a_side
  art = Art.new(center: [0, 5.5], scale: 4.6, label: "Type 422A perpendicular curb ramp with side curbs")
  curb = Curb.straight
  hw, sc, run = 2.5, 0.5, 6.0
  curb.dip(curb.hit([-hw, 0], [0, -1]), curb.hit([hw, 0], [0, -1]), 0, 0)
  straight_ground(art, curb, strip: run, walk: 6.0) do
    art.crosswalk([0, 0], [1, 0], [0, -1])
    art.clear_area([[-hw, 0, 0], [hw, 0, 0], [hw, -4, 0], [-hw, -4, 0]])
  end
  art.joint([-80, run, CH], [-hw - sc, run, CH], op: 0.55)
  art.joint([hw + sc, run, CH], [80, run, CH], op: 0.55)
  art.surface([[-hw, 0, 0], [hw, 0, 0], [hw, run, CH], [-hw, run, CH]])
  art.brush((1..16).map { |i| v = i * 0.35; [[-hw, v, CH * v / run], [hw, v, CH * v / run]] })
  art.face([[-hw, 0, 0], [-hw, 0, CH], [-hw, run, CH]]) # inner face of each side curb
  [-1, 1].each do |sx|
    a, b = sx * hw, sx * (hw + sc)
    art.face([[a, 0, 0], [b, 0, 0], [b, 0, CH], [a, 0, CH]])
    art.fill([[a, 0, CH], [b, 0, CH], [b, run, CH], [a, run, CH]], "#d8d0bd")
  end
  art.fill([[-hw, run, CH], [hw, run, CH], [hw, run + 4, CH], [-hw, run + 4, CH]], Art::CONCRETE)
  art.warning(2 * hw) { |u, v| [-hw + u, v, CH * v / run] }
  art.joint([-hw, run, CH], [hw, run, CH])
  art.joint([-hw, run, CH], [-hw, run + 4, CH], [hw, run + 4, CH], [hw, run, CH])
  art.curb_edge(curb)
  art
end

def scene_422b
  art = Art.new(center: [0, 4.5], scale: 4.4, label: "Type 422B parallel curb ramp")
  curb = Curb.straight
  lw, run, wd = 2.5, 6.0, 6.0
  curb.dip(curb.hit([-lw, 0], [0, -1]), curb.hit([lw, 0], [0, -1]), run, run)
  straight_ground(art, curb, walk: wd) { art.crosswalk([0, 0], [1, 0], [0, -1]) }
  art.fill([[-80, wd, CH], [80, wd, CH], [80, wd + 0.5, CH], [-80, wd + 0.5, CH]], "#d8d0bd") # back curb
  art.surface([[-lw, 0, 0], [lw, 0, 0], [lw, wd, 0], [-lw, wd, 0]])
  [-1, 1].each do |sx|
    a, b = sx * lw, sx * (lw + run)
    art.surface([[a, 0, 0], [b, 0, CH], [b, wd, CH], [a, wd, 0]])
    art.brush((1..16).map { |i| x = a + sx * i * 0.35; h = CH * i * 0.35 / run; [[x, 0, h], [x, wd, h]] })
    art.face([[a, wd, 0], [b, wd, CH], [a, wd, CH]])
  end
  art.face([[-lw, wd, 0], [lw, wd, 0], [lw, wd, CH], [-lw, wd, CH]])
  art.warning(2 * lw) { |u, v| [-lw + u, v, 0] }
  [lw, lw + run].each do |x|
    h = x == lw ? 0 : CH
    art.joint([-x, 0, h], [-x, wd, h])
    art.joint([x, 0, h], [x, wd, h])
  end
  art.curb_edge(curb)
  art
end

# Ground for a corner: bottom street (z < 0), right street (x > 0), a curb return
# of radius r, sidewalks `walk` wide behind `strip` feet of planting strip, and
# the paved corner reaching back to `inner` (a point behind the return).
def corner_ground(art, curb, r, strip: 5.0, walk: 7.0, inner: nil)
  art.street
  yield if block_given?
  art.curb_faces(curb)
  big = 200
  art.grass(curb.walk(0, curb.length, 1.0, height: CH) + [[-big, big, CH]])
  back = strip + walk
  inner ||= [-back, back]
  arc = curb.walk(curb.hit([-r, 1], [0, -1]), curb.hit([-1, r], [1, 0]), 0.5, height: CH)
  art.concrete(arc + [[0, r, CH], [-back, r, CH], [inner[0], inner[1], CH], [-r, back, CH], [-r, 0, CH]])
  art.concrete([[-big, strip, CH], [-r + 0.01, strip, CH], [-r + 0.01, back, CH], [-big, back, CH]])
  art.concrete([[-back, r - 0.01, CH], [-strip, r - 0.01, CH], [-strip, big, CH], [-back, big, CH]])
end

def scene_422c
  r, wd, run = 12.0, 6.0, 6.0
  art = Art.new(center: [-8, 8], scale: 3.5, label: "Type 422C parallel curb ramps at the corner")
  curb = Curb.corner(r)
  s0, s1 = curb.hit([-r, 1], [0, -1]), curb.hit([-1, r], [1, 0])
  curb.dip(s0, s1, run, run)
  c = [-r, r]
  ring = ->(rad, h) { (0..45).map { a = (2 * _1 - 90) * Math::PI / 180; [c[0] + rad * Math.cos(a), c[1] + rad * Math.sin(a), h] } }
  corner_ground(art, curb, r, strip: 0, walk: wd) do
    art.crosswalk([-r + 3, 0], [1, 0], [0, -1])
    art.crosswalk([0, r - 3], [0, 1], [1, 0])
  end
  # landscape behind the back curb, inside the return
  art.grass(ring.(r - wd - 0.5, CH) + [[-r, r, CH]])
  art.surface(ring.(r, 0) + ring.(r - wd, 0).reverse)
  art.face(ring.(r - wd, 0) + ring.(r - wd, CH).reverse)
  art.fill(ring.(r - wd, CH) + ring.(r - wd - 0.5, CH).reverse, "#d8d0bd")
  # runs along each street, rising away from the corner
  art.surface([[-r, 0, 0], [-r, wd, 0], [-r - run, wd, CH], [-r - run, 0, CH]])
  art.brush((1..16).map { |i| x = -r - i * 0.35; h = CH * i * 0.35 / run; [[x, 0, h], [x, wd, h]] })
  art.face([[-r, wd, 0], [-r - run, wd, CH], [-r, wd, CH]])
  art.fill([[-r - run, wd, CH], [-r, wd, CH], [-r, wd + 0.5, CH], [-r - run, wd + 0.5, CH]], "#d8d0bd")
  art.surface([[0, r, 0], [0, r + run, CH], [-wd, r + run, CH], [-wd, r, 0]])
  art.brush((1..16).map { |i| z = r + i * 0.35; h = CH * i * 0.35 / run; [[0, z, h], [-wd, z, h]] })
  [[-r + 3, 20], [-20, r - 3]].each do |p|
    sm = curb.hit(p, p[0] == -20 ? [1, 0] : [0, -1])
    art.warning(5.0) { |u, v| s = sm - 2.5 + u; q = add(curb.at(s), mul(curb.inward(s), v + 0.1)); [q[0], q[1], 0] }
  end
  art.joint([-r, 0, 0], [-r, wd, 0])
  art.joint([-r - run, 0, CH], [-r - run, wd, CH])
  art.joint([0, r, 0], [-wd, r, 0])
  art.joint([0, r + run, CH], [-wd, r + run, CH])
  art.curb_edge(curb)
  art
end

def directional(type)
  r = 30.0
  art = Art.new(center: [-13, 10], scale: 3.3,
                label: "Type #{type.upcase} directional curb ramp#{' set back from the curb' if type == '422e'}")
  curb = Curb.corner(r)
  x = -12.0
  zc = curb.at(curb.hit([x, 40], [0, -1]))[1]
  zb = type == "422d" ? zc + 4.1 : zc + 6.0
  bc = [x, zb]
  # lower the curb before it's drawn (ramp() lowers it again, to the same heights)
  curb.dip(curb.hit([x - 2.5, zb], [0, -1]), curb.hit([x + 2.5, zb], [0, -1]), 5.0, 6.0)
  corner_ground(art, curb, r, inner: [-18, 18]) { art.crosswalk([x, 0], [1, 0], [0, -1]) }
  ramp(art, curb, bc, [0, 1], wings: [5.0, 6.0], warn: type == "422d" ? :bottom : :curb, clear: [5.0, 4.0])
  art.curb_edge(curb)
  art
end

def scene_422f
  r = 16.0
  art = Art.new(center: [-7, 6.5], scale: 3.9, label: "Type 422F shared diagonal curb ramp")
  curb = Curb.corner(r)
  a = 45 * Math::PI / 180
  apex = [-r + r * Math.cos(-a), r + r * Math.sin(-a)]
  d = unit([-1, 1])
  bc = add(apex, mul(d, 0.25))
  n = [d[1], -d[0]]
  curb.dip(curb.hit(add(bc, mul(n, -2.5)), mul(d, -1)), curb.hit(add(bc, mul(n, 2.5)), mul(d, -1)), 6.0, 6.0)
  corner_ground(art, curb, r) do
    art.crosswalk([apex[0], 0], [1, 0], [0, -1])
    art.crosswalk([0, apex[1]], [0, 1], [1, 0])
    art.faint([0, -1, 0], [0, -40, 0]) # face of curb extended
    art.faint([1, 0, 0], [40, 0, 0])
  end
  ramp(art, curb, bc, d, wings: [6.0, 6.0], warn: :ramp, clear: [5.0, 4.0])
  art.curb_edge(curb)
  art
end

def scene_422g
  r, band = 20.0, 10.0 # 6" at 5% max
  art = Art.new(center: [-10, 9], scale: 3.4, label: "Type 422G blended transition")
  curb = Curb.corner(r)
  s0, s1 = curb.hit([-r, 1], [0, -1]), curb.hit([-1, r], [1, 0])
  curb.dip(s0, s1, 5.0, 5.0)
  c = [-r, r]
  ring = ->(rad, h) { (0..45).map { a = (2 * _1 - 90) * Math::PI / 180; [c[0] + rad * Math.cos(a), c[1] + rad * Math.sin(a), h] } }
  corner_ground(art, curb, r, inner: [-18, 18]) do
    art.crosswalk([-r + 8, 0], [1, 0], [0, -1])
    art.crosswalk([0, r - 8], [0, 1], [1, 0])
  end
  outer, inner = ring.(r, 0), ring.(r - band, CH)
  45.times { |i| art.surface([outer[i], outer[i + 1], inner[i + 1], inner[i]], seam: true) }
  art.brush((0..45).map { [outer[_1], inner[_1]] })
  art.surface([[-r, 0, 0], [-r, band, CH], [-r - 5, 0, CH]])
  art.surface([[0, r, 0], [0, r + 5, CH], [-band, r, CH]])
  art.warning(s1 - s0) { |u, v| s = s0 + u; q = add(curb.at(s), mul(curb.inward(s), v + 0.1)); [q[0], q[1], 0] }
  art.joint([-r - 5, 0, CH], *inner, [0, r + 5, CH])
  art.curb_edge(curb)
  art
end

def scene_422h
  art = Art.new(center: [0, 1], scale: 4.4, label: "Type 422H island cut-through")
  hw, iz = 2.5, 3.0 # 5' path; 6' island = 2' panel + 2' gap + 2' panel
  art.street
  art.crosswalk([0, -iz], [1, 0], [0, -1])
  art.crosswalk([0, iz], [1, 0], [0, 1], from: 2.0)
  [-1, 1].each do |sx|
    a, b = sx * hw, sx * 40
    art.fill([[a, -iz, 0], [b, -iz, 0], [b, -iz, CH], [a, -iz, CH]], "#a89e88")
    art.fill([[a, -iz, CH], [b, -iz, CH], [b, iz, CH], [a, iz, CH]], "url(#grass)")
    art.concrete([[a, -iz, CH], [b, -iz, CH], [b, -iz + 1.0, CH], [a, -iz + 1.0, CH]])
    art.concrete([[a, iz - 1.0, CH], [b, iz - 1.0, CH], [b, iz, CH], [a, iz, CH]])
    art.raw(%(<path d="#{art.path([[a, -iz, CH], [b, -iz, CH]], close: false)}" stroke="#fffdf6" stroke-width="#{f2(art.s * 0.14)}"/>))
    art.face([[a, -iz, 0], [a, iz, 0], [a, iz, CH], [a, -iz, CH]])
  end
  art.surface([[-hw, -iz, 0], [hw, -iz, 0], [hw, iz, 0], [-hw, iz, 0]], "#d9d2c1")
  art.warning(2 * hw) { |u, v| [-hw + u, -iz + v, 0] }
  art.warning(2 * hw) { |u, v| [-hw + u, iz - 2 + v, 0] }
  art
end

SCENES = {
  "422a" => [:scene_422a, "Type 422A perpendicular curb ramp with wings"],
  "422a-side-curbs" => [:scene_422a_side, "Type 422A perpendicular curb ramp with side curbs"],
  "422b" => [:scene_422b, "Type 422B parallel curb ramp"],
  "422c" => [:scene_422c, "Type 422C parallel curb ramps at the corner"],
  "422d" => [->() { directional("422d") }, "Type 422D directional curb ramp"],
  "422e" => [->() { directional("422e") }, "Type 422E directional curb ramp, set back from the curb"],
  "422f" => [:scene_422f, "Type 422F shared diagonal curb ramp"],
  "422g" => [:scene_422g, "Type 422G blended transition"],
  "422h" => [:scene_422h, "Type 422H island cut-through"],
}.freeze

if $PROGRAM_NAME == __FILE__
  Dir.mkdir(OUT) unless Dir.exist?(OUT)
  only = ARGV.reject { _1.start_with?("-") }
  SCENES.each do |id, (build, title)|
    next unless only.empty? || only.include?(id)

    art = build.is_a?(Proc) ? build.call : send(build)
    File.write(File.join(OUT, "#{id}.svg"), art.to_svg("#{title}, drawn from the City of Seattle Standard Plans"))
    puts "wrote docs/seattle/curb-ramps/#{id}.svg"
  end
end
