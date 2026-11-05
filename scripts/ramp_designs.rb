# frozen_string_literal: true

# Every City of Seattle curb ramp design, described once: plan geometry (in
# feet) and the words that go with it. scripts/catalog.rb draws each one as an
# illustration and writes the catalog page; scripts/ramp_model.rb builds each
# one as a true-scale 3D model for the AR page. Standard library only.
#
# Source: 2026 City of Seattle Standard Plans for Municipal Construction.
#   420   sidewalk scoring in 2' squares
#   422a  perpendicular ramp: 5'-0" wide (4'-0" min), 8.3% max (6'-0" run for a 6"
#         curb), wings at 10% max, 4'-0" landing, 4'-0" clear area. Second drawing:
#         side curbs instead of wings across a planting strip (5'-0" min). Location
#         inset: ramps radial to the curb on a curb return.
#   422b  parallel ramp: runs 6'-0" wide (5'-0" min) at 8.3%, 5'-0" min lower
#         landing at street level, 4'-0" of full-width sidewalk at the top of each
#         run, back curb. Second drawing: the landing reaches the curb through a
#         planting strip between side curbs.
#   422c  parallel ramps at the corner: first drawing, a landing that wraps the curb
#         return with a curved back curb; second, a square landing where two
#         sidewalks set behind planting strips meet, paved flush out to the curb.
#         Radial-tile warning panels, 5'-0" turning space.
#   422d  directional ramp: centerline parallel to the crosswalk, bottom 5'-0" or
#         less from the curb, warning panel at the bottom of the run, 4'-0" clear
#         area; wings (first drawing) or side curbs where the sidewalk runs into the
#         curve between planting strips (second drawing)
#   422e  directional ramp more than 5'-0" back from the curb: the warning panel
#         moves to the back of curb (radial tile), 2'-0" min from the ramp
#   422f  shared diagonal ramp at the apex: panel within 8" of the curb, 5'-0" x
#         4'-0" clear area inside both curb lines extended
#   422g  blended transition: 5% max down to the street, radial panel along the
#         whole curb, wings at 10%, level bypass behind
#   422h  island cut-through: 5'-0" min path at street level, 2'-0" panels at
#         least 2'-0" apart
#   422k  panels 2'-0" deep, Federal Safety Yellow; side/back curbs 6" wide
#   712   ladder crosswalk: pairs of 8" bars with an 8" gap, 10' long, 5' apart
#
# Coordinates: x along the bottom street's curb (right is +x), z away from that
# street into the sidewalk, h height above the street. Corner designs put the
# second street at x > 0 with a curb return of radius r between them.

CH = 0.5 # 6" curb, feet
PDF = "https://www.seattle.gov/documents/Departments/SPU/Construction-Resources/standards-guidelines/specifications-plans/2026-Standard-Plans.pdf"

def add(a, b) = a.zip(b).map { _1 + _2 }
def sub(a, b) = a.zip(b).map { _1 - _2 }
def mul(a, s) = a.map { _1 * s }
def dist(a, b) = Math.hypot(a[0] - b[0], a[1] - b[1])
def unit(a) = mul(a, 1 / Math.hypot(*a))

# A curb line in plan, walked from the bottom street (left) toward the right
# street, so the sidewalk is always on the left. Heights along it are 6" except
# where a ramp lowers it.
class Curb
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
    i = ((@cum.bsearch_index { _1 > s } || @cum.size - 1) - 1).clamp(0, @pts.size - 2)
    seg = @cum[i + 1] - @cum[i]
    add(@pts[i], mul(sub(@pts[i + 1], @pts[i]), seg.zero? ? 0 : (s - @cum[i]) / seg))
  end

  # Unit vector pointing into the sidewalk at s.
  def inward(s)
    t = unit(sub(at(s + 0.05), at(s - 0.05)))
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

# What a design is made of, in drawing order (later things sit on top). Each
# entry is [kind, *args]; the illustration and the 3D model each read the kinds
# they use.
#   surfaces: :grass, :walk (level sidewalk), :landing (level, at a ramp),
#             :ramp, :flush (street-level concrete), :wing, :curbtop
#   solids:   :wall (a vertical face), :curb (curb faces along a stretch of curb)
#   on top:   :warning, :joint, :clear (the clear area's outline)
#   drawing only: :street, :crosswalk, :edge (lit curb edge), :brush, :faint, :rim
class Scene
  attr_reader :ops

  def initialize = @ops = []
  def method_missing(kind, *args, **kw, &blk) = @ops << [kind, args, kw, blk]
  def respond_to_missing?(*) = true
end

# A perpendicular or directional ramp. `bc` is the middle of its lower grade
# break, `d` points up the run. Wings slope from the top of the run down to the
# curb, `wings` feet along the curb on each side. `warn` places the 2' panel:
# :ramp (on the run, at the curb), :bottom (at the foot of the run, on the
# flush area), :curb (along the back of curb, radial tile).
def ramp(sc, curb, bc, d, w: 5.0, run: 6.0, landing: 4.0, wings: [5.0, 5.0], warn: :ramp, clear: [4.0, 4.0])
  n = [d[1], -d[0]]
  bl, br = add(bc, mul(n, -w / 2)), add(bc, mul(n, w / 2))
  tl, tr = add(bl, mul(d, run)), add(br, mul(d, run))
  ll, lr = add(tl, mul(d, landing)), add(tr, mul(d, landing))
  back = mul(d, -1)
  sl, sr = curb.hit(bl, back), curb.hit(br, back)
  curb.dip(sl, sr, wings[0], wings[1])
  e = ->(p, h) { [p[0], p[1], h] }

  if dist(bl, curb.at(sl)) > 0.05 || dist(br, curb.at(sr)) > 0.05
    sc.surface(curb.walk(sl, sr, 0.3, height: 0) + [e[br, 0], e[bl, 0]], kind: :flush)
  end
  sc.surface([e[bl, 0], e[br, 0], e[tr, CH], e[tl, CH]], kind: :ramp)
  sc.surface([e[tl, CH]] + curb.walk(sl - wings[0], sl) + [e[bl, 0]], kind: :wing)
  sc.surface([e[tr, CH], e[br, 0]] + curb.walk(sr, sr + wings[1]), kind: :wing)
  sc.surface([e[tl, CH], e[tr, CH], e[lr, CH], e[ll, CH]], kind: :landing)
  sc.brush((1..(run / 0.35).floor - 1).map { |i| v = i * 0.35; [e[add(bl, mul(d, v)), CH * v / run], e[add(br, mul(d, v)), CH * v / run]] })

  if clear
    cw, cd = clear[0] / 2, clear[1]
    sc.clear([mul(n, -cw), mul(n, cw), add(mul(n, cw), mul(back, cd)), add(mul(n, -cw), mul(back, cd))].map { e[add(bc, _1), 0] })
  end

  case warn
  when :ramp then sc.warning(w) { |u, v| p = add(add(bl, mul(n, u)), mul(d, v)); e[p, CH * v / run] }
  when :bottom then sc.warning(w) { |u, v| p = add(add(bl, mul(n, u)), mul(d, v - 2.0)); e[p, 0] }
  when :curb then curb_warning(sc, curb, sl, sr, sides: [[bl, d], [br, d]])
  end

  sc.joint(e[curb.at(sl - wings[0]), CH], e[tl, CH], e[tr, CH], e[curb.at(sr + wings[1]), CH])
  sc.joint(e[tl, CH], e[ll, CH], e[lr, CH], e[tr, CH])
end

# A warning panel in radial tile, along the back of curb from s0 to s1.
# `rise` is the slope of the surface it sits on, away from the curb. `sides`
# ([point, direction] lines, one per end) cut the ends along the path of travel,
# as the plans draw them, instead of square to the curb.
def curb_warning(sc, curb, s0, s1, rise: 0, sides: nil)
  off = ->(s, v) { add(curb.at(s), mul(curb.inward(s), v + 0.1)) }
  ends = lambda do |v|
    next [s0, s1] unless sides

    [s0, s1].zip(sides).map do |guess, (pt, dir)|
      f = ->(s) { q = sub(off.(s, v), pt); dir[0] * q[1] - dir[1] * q[0] }
      lo, hi = guess - 4.0, guess + 4.0
      next guess if (f.(lo) <=> 0) == (f.(hi) <=> 0)

      40.times { mid = (lo + hi) / 2; (f.(lo) <=> 0) == (f.(mid) <=> 0) ? lo = mid : hi = mid }
      (lo + hi) / 2
    end
  end
  sc.warning(s1 - s0) do |u, v|
    a, b = ends.(v)
    q = off.(a + (b - a) * u / (s1 - s0), v)
    [q[0], q[1], rise * (v + 0.1)]
  end
end

# Ground for a straight curb along z = 0: a planting strip, then sidewalk `walk`
# feet deep, then grass.
def straight_ground(sc, curb, strip: 0.0, walk: 12.0)
  sc.street
  yield if block_given?
  sc.curb(curb)
  sc.surface([[-80, 0, CH], [80, 0, CH], [80, 80, CH], [-80, 80, CH]], kind: :grass)
  sc.surface([[-80, strip, CH], [80, strip, CH], [80, strip + walk, CH], [-80, strip + walk, CH]], kind: :walk)
  sc.rim([-80, strip + walk, CH], [80, strip + walk, CH])
end

# Ground for a corner: bottom street (z < 0), right street (x > 0), a curb return
# of radius r, sidewalks `walk` wide behind `strip` feet of planting strip, and
# the paved corner reaching back to `inner` (a point behind the return).
def corner_ground(sc, curb, r, strip: 5.0, walk: 7.0, inner: nil, pad: true)
  sc.street
  yield if block_given?
  sc.curb(curb)
  big = 200
  sc.surface(curb.walk(0, curb.length, 1.0, height: CH) + [[-big, big, CH]], kind: :grass)
  back = strip + walk
  inner ||= [-back, back]
  if pad
    arc = curb.walk(curb.hit([-r, 1], [0, -1]), curb.hit([-1, r], [1, 0]), 0.5, height: CH)
    sc.surface(arc + [[0, r, CH], [-back, r, CH], [inner[0], inner[1], CH], [-r, back, CH], [-r, 0, CH]], kind: :walk)
  end
  sc.surface([[-big, strip, CH], [-r + 0.01, strip, CH], [-r + 0.01, back, CH], [-big, back, CH]], kind: :walk)
  sc.surface([[-back, r - 0.01, CH], [-strip, r - 0.01, CH], [-strip, big, CH], [-back, big, CH]], kind: :walk)
end

def arc_pts(c, rad, h, a0 = -90, a1 = 0, n = 45)
  (0..n).map { a = (a0 + (a1 - a0) * _1.to_f / n) * Math::PI / 180; [c[0] + rad * Math.cos(a), c[1] + rad * Math.sin(a), h] }
end

# ------------------------------------------------------------------ designs

def build_422a(sc)
  curb = Curb.straight
  curb.dip(curb.hit([-2.5, 0], [0, -1]), curb.hit([2.5, 0], [0, -1]), 5, 5)
  straight_ground(sc, curb, walk: 10.0) { sc.crosswalk([0, 0], [1, 0], [0, -1]) }
  [-11.5, 11.5].each { |x| sc.joint([x, 0, CH], [x, 10, CH], op: 0.5) } # contraction joints
  ramp(sc, curb, [0, 0], [0, 1], clear: [4.0, 4.0])
  sc.edge(curb)
end

def build_422a_side_curbs(sc)
  curb = Curb.straight
  hw, w6, run = 2.5, 0.5, 6.0
  curb.dip(curb.hit([-hw, 0], [0, -1]), curb.hit([hw, 0], [0, -1]), 0, 0)
  straight_ground(sc, curb, strip: run, walk: 6.0) do
    sc.crosswalk([0, 0], [1, 0], [0, -1])
    sc.clear([[-hw, 0, 0], [hw, 0, 0], [hw, -4, 0], [-hw, -4, 0]])
  end
  sc.joint([-80, run, CH], [-hw - w6, run, CH], op: 0.55)
  sc.joint([hw + w6, run, CH], [80, run, CH], op: 0.55)
  sc.surface([[-hw, 0, 0], [hw, 0, 0], [hw, run, CH], [-hw, run, CH]], kind: :ramp)
  sc.brush((1..16).map { |i| v = i * 0.35; [[-hw, v, CH * v / run], [hw, v, CH * v / run]] })
  [-1, 1].each do |sx|
    a, b = sx * hw, sx * (hw + w6)
    sc.surface([[a, 0, CH], [b, 0, CH], [b, run, CH], [a, run, CH]], kind: :curbtop)
    sc.wall([[a, 0, 0], [a, 0, CH], [a, run, CH]])          # inner face of the side curb
    sc.wall([[a, 0, 0], [b, 0, 0], [b, 0, CH], [a, 0, CH]]) # its end at the street
  end
  sc.surface([[-hw, run, CH], [hw, run, CH], [hw, run + 4, CH], [-hw, run + 4, CH]], kind: :landing)
  sc.warning(2 * hw) { |u, v| [-hw + u, v, CH * v / run] }
  sc.joint([-hw, run, CH], [hw, run, CH])
  sc.joint([-hw, run, CH], [-hw, run + 4, CH], [hw, run + 4, CH], [hw, run, CH])
  sc.edge(curb)
end

# Two 422a ramps on a curb return, each radial to the curb (422a location inset).
def build_422a_radius(sc)
  r = 25.0
  curb = Curb.corner(r)
  c = [-r, r]
  spots = [-68, -22].map do |deg|
    a = deg * Math::PI / 180
    p = [c[0] + r * Math.cos(a), c[1] + r * Math.sin(a)]
    d = unit(sub(c, p))
    n = [d[1], -d[0]]
    bc = add(p, mul(d, 0.2)) # the curve bows out a little under a 5' ramp
    curb.dip(curb.hit(add(bc, mul(n, -2.5)), mul(d, -1)), curb.hit(add(bc, mul(n, 2.5)), mul(d, -1)), 5, 5)
    [bc, d, p]
  end
  corner_ground(sc, curb, r) do
    sc.crosswalk([spots[0][2][0], 0], [1, 0], [0, -1])
    sc.crosswalk([0, spots[1][2][1]], [0, 1], [1, 0])
  end
  spots.each { |bc, d, _| ramp(sc, curb, bc, d) }
  sc.edge(curb)
end

def build_422b(sc)
  curb = Curb.straight
  lw, run, wd = 2.5, 6.0, 6.0
  curb.dip(curb.hit([-lw, 0], [0, -1]), curb.hit([lw, 0], [0, -1]), run, run)
  straight_ground(sc, curb, walk: wd) { sc.crosswalk([0, 0], [1, 0], [0, -1]) }
  sc.surface([[-80, wd, CH], [80, wd, CH], [80, wd + 0.5, CH], [-80, wd + 0.5, CH]], kind: :curbtop) # back curb
  sc.surface([[-lw, 0, 0], [lw, 0, 0], [lw, wd, 0], [-lw, wd, 0]], kind: :flush)
  [-1, 1].each do |sx|
    a, b = sx * lw, sx * (lw + run)
    sc.surface([[a, 0, 0], [b, 0, CH], [b, wd, CH], [a, wd, 0]], kind: :ramp)
    sc.brush((1..16).map { |i| x = a + sx * i * 0.35; h = CH * i * 0.35 / run; [[x, 0, h], [x, wd, h]] })
    sc.wall([[a, wd, 0], [b, wd, CH], [a, wd, CH]])
  end
  sc.wall([[-lw, wd, 0], [lw, wd, 0], [lw, wd, CH], [-lw, wd, CH]])
  sc.warning(2 * lw) { |u, v| [-lw + u, v, 0] }
  [lw, lw + run].each do |x|
    h = x == lw ? 0 : CH
    sc.joint([-x, 0, h], [-x, wd, h])
    sc.joint([x, 0, h], [x, wd, h])
  end
  sc.edge(curb)
end

# 422b's second drawing: the sidewalk sits behind a planting strip, and the
# lower landing reaches through the strip to the curb between side curbs.
def build_422b_strip(sc)
  curb = Curb.straight
  lw, run, wd, strip, w6 = 2.5, 6.0, 6.0, 5.0, 0.5
  top = strip + wd
  curb.dip(curb.hit([-lw, 0], [0, -1]), curb.hit([lw, 0], [0, -1]), 0, 0)
  straight_ground(sc, curb, strip: strip, walk: wd) { sc.crosswalk([0, 0], [1, 0], [0, -1]) }
  sc.surface([[-80, top, CH], [80, top, CH], [80, top + 0.5, CH], [-80, top + 0.5, CH]], kind: :curbtop) # back curb
  sc.surface([[-lw, 0, 0], [lw, 0, 0], [lw, top, 0], [-lw, top, 0]], kind: :flush)
  [-1, 1].each do |sx|
    a, b, c = sx * lw, sx * (lw + run), sx * (lw + w6)
    sc.surface([[a, strip, 0], [b, strip, CH], [b, top, CH], [a, top, 0]], kind: :ramp)
    sc.brush((1..16).map { |i| x = a + sx * i * 0.35; h = CH * i * 0.35 / run; [[x, strip, h], [x, top, h]] })
    sc.surface([[a, 0, CH], [c, 0, CH], [c, strip - w6, CH], [a, strip - w6, CH]], kind: :curbtop) # side curb
    sc.surface([[a, strip - w6, CH], [b, strip - w6, CH], [b, strip, CH], [a, strip, CH]], kind: :curbtop) # along the run
    sc.wall([[a, 0, 0], [a, strip, 0], [a, strip, CH], [a, 0, CH]])
    sc.wall([[a, 0, 0], [c, 0, 0], [c, 0, CH], [a, 0, CH]])
    sc.wall([[a, strip, 0], [b, strip, CH], [a, strip, CH]])
    sc.wall([[a, top, 0], [b, top, CH], [a, top, CH]])
  end
  sc.wall([[-lw, top, 0], [lw, top, 0], [lw, top, CH], [-lw, top, CH]])
  sc.warning(2 * lw) { |u, v| [-lw + u, v, 0] }
  [lw, lw + run].each do |x|
    h = x == lw ? 0 : CH
    sc.joint([-x, strip, h], [-x, top, h])
    sc.joint([x, strip, h], [x, top, h])
  end
  sc.edge(curb)
end

def build_422c(sc)
  r, wd, run = 12.0, 6.0, 6.0
  curb = Curb.corner(r)
  s0, s1 = curb.hit([-r, 1], [0, -1]), curb.hit([-1, r], [1, 0])
  curb.dip(s0, s1, run, run)
  c = [-r, r]
  corner_ground(sc, curb, r, strip: 0, walk: wd) do
    sc.crosswalk([-r + 3, 0], [1, 0], [0, -1])
    sc.crosswalk([0, r - 3], [0, 1], [1, 0])
  end
  sc.surface(arc_pts(c, r - wd - 0.5, CH) + [[-r, r, CH]], kind: :grass) # landscape behind the back curb
  outer, inner = arc_pts(c, r, 0), arc_pts(c, r - wd, 0)
  45.times { |i| sc.surface([outer[i], outer[i + 1], inner[i + 1], inner[i]], kind: :flush, seam: true) }
  ring = arc_pts(c, r - wd, CH)
  45.times do |i|
    sc.wall([inner[i], inner[i + 1], ring[i + 1], ring[i]])
    sc.surface([ring[i], ring[i + 1], arc_pts(c, r - wd - 0.5, CH)[i + 1], arc_pts(c, r - wd - 0.5, CH)[i]], kind: :curbtop, seam: true)
  end
  # runs along each street, rising away from the corner, with a back curb behind
  sc.surface([[-r, 0, 0], [-r, wd, 0], [-r - run, wd, CH], [-r - run, 0, CH]], kind: :ramp)
  sc.brush((1..16).map { |i| x = -r - i * 0.35; h = CH * i * 0.35 / run; [[x, 0, h], [x, wd, h]] })
  sc.wall([[-r, wd, 0], [-r - run, wd, CH], [-r, wd, CH]])
  sc.surface([[-r - run, wd, CH], [-r, wd, CH], [-r, wd + 0.5, CH], [-r - run, wd + 0.5, CH]], kind: :curbtop)
  sc.surface([[0, r, 0], [0, r + run, CH], [-wd, r + run, CH], [-wd, r, 0]], kind: :ramp)
  sc.brush((1..16).map { |i| z = r + i * 0.35; h = CH * i * 0.35 / run; [[0, z, h], [-wd, z, h]] })
  sc.wall([[-wd, r, 0], [-wd, r + run, CH], [-wd, r, CH]])
  sc.surface([[-wd, r, CH], [-wd, r + run, CH], [-wd - 0.5, r + run, CH], [-wd - 0.5, r, CH]], kind: :curbtop)
  [[-r + 3, 20], [-20, r - 3]].each do |p|
    sm = curb.hit(p, p[0] == -20 ? [1, 0] : [0, -1])
    curb_warning(sc, curb, sm - 2.5, sm + 2.5)
  end
  sc.joint([-r, 0, 0], [-r, wd, 0])
  sc.joint([-r - run, 0, CH], [-r - run, wd, CH])
  sc.joint([0, r, 0], [-wd, r, 0])
  sc.joint([0, r + run, CH], [-wd, r + run, CH])
  sc.edge(curb)
end

# 422c's second drawing: sidewalks set behind planting strips meet at a square
# landing, paved flush with the street out to the curb.
def build_422c_square(sc)
  r, strip, wd, run = 15.0, 5.0, 6.0, 6.0
  back = strip + wd
  curb = Curb.corner(r)
  sa, sb = curb.hit([-back, 20], [0, -1]), curb.hit([-20, back], [1, 0])
  curb.dip(sa, sb, 0, 0)
  corner_ground(sc, curb, r, strip: strip, walk: wd, pad: false) do
    sc.crosswalk([-back + 3, 0], [1, 0], [0, -1])
    sc.crosswalk([0, back - 3], [0, 1], [1, 0])
  end
  sc.surface(curb.walk(sa, sb, 0.3, height: 0) + [[-back, back, 0]], kind: :flush)
  za = curb.at(sa)[1]
  xb = curb.at(sb)[0]
  sc.wall([[-back, za, 0], [-back, strip, 0], [-back, strip, CH], [-back, za, CH]])
  sc.wall([[xb, back, 0], [-strip, back, 0], [-strip, back, CH], [xb, back, CH]])
  # runs along each sidewalk, down to the landing
  sc.surface([[-back, strip, 0], [-back, back, 0], [-back - run, back, CH], [-back - run, strip, CH]], kind: :ramp)
  sc.brush((1..16).map { |i| x = -back - i * 0.35; h = CH * i * 0.35 / run; [[x, strip, h], [x, back, h]] })
  sc.surface([[-strip, back, 0], [-strip, back + run, CH], [-back, back + run, CH], [-back, back, 0]], kind: :ramp)
  sc.brush((1..16).map { |i| z = back + i * 0.35; h = CH * i * 0.35 / run; [[-strip, z, h], [-back, z, h]] })
  [strip, back].each do |z|
    sc.wall([[-back, z, 0], [-back - run, z, CH], [-back, z, CH]])
    sc.wall([[-z, back, 0], [-z, back + run, CH], [-z, back, CH]])
  end
  curb_warning(sc, curb, sa, sb, sides: [[[-back, 0], [0, 1]], [[0, back], [1, 0]]])
  sc.joint([-back, strip, 0], [-back, back, 0], [-strip, back, 0])
  sc.joint([-back - run, strip, CH], [-back - run, back, CH])
  sc.joint([-strip, back + run, CH], [-back, back + run, CH])
  sc.edge(curb)
end

def build_directional(sc, type)
  r = 30.0
  curb = Curb.corner(r)
  x = -12.0
  zc = curb.at(curb.hit([x, 40], [0, -1]))[1]
  zb = type == "422d" ? zc + 4.1 : zc + 6.0
  bc = [x, zb]
  curb.dip(curb.hit([x - 2.5, zb], [0, -1]), curb.hit([x + 2.5, zb], [0, -1]), 5.0, 6.0)
  corner_ground(sc, curb, r, inner: [-18, 18]) { sc.crosswalk([x, 0], [1, 0], [0, -1]) }
  ramp(sc, curb, bc, [0, 1], wings: [5.0, 6.0], warn: type == "422d" ? :bottom : :curb, clear: [5.0, 4.0])
  sc.edge(curb)
end

# The second drawing on 422d and 422e: the sidewalk runs straight into the
# curve between planting strips, and the ramp is that sidewalk sloping down
# between side curbs, aimed along the crosswalk across the other street.
def build_directional_side(sc, type)
  r, strip, wd, run = 30.0, 6.0, 5.0, 6.0
  z0, z1 = strip, strip + wd
  curb = Curb.corner(r)
  s0, s1 = curb.hit([-40, z0], [1, 0]), curb.hit([-40, z1], [1, 0])
  near = curb.at(s0)[0]                        # where the sidewalk's street edge meets the curb
  xb = type == "422d" ? near - 2.2 : near - 6.0 # bottom of the run
  xt = xb - run
  curb.dip(s0, s1, 0, 0)
  sc.street
  zc = (z0 + z1) / 2
  sc.crosswalk([curb.at(curb.hit([-40, zc], [1, 0]))[0], zc], [0, 1], [1, 0])
  sc.curb(curb)
  sc.surface(curb.walk(0, curb.length, 1.0, height: CH) + [[-200, 200, CH]], kind: :grass)
  sc.surface([[-200, z0, CH], [xt, z0, CH], [xt, z1, CH], [-200, z1, CH]], kind: :walk)
  sc.surface([[xt, z0, CH], [xb, z0, 0], [xb, z1, 0], [xt, z1, CH]], kind: :ramp)
  sc.brush((1..16).map { |i| x = xt + i * 0.35; h = CH * (1 - i * 0.35 / run); [[x, z0, h], [x, z1, h]] })
  sc.surface([[xb, z0, 0]] + curb.walk(s0, s1, 0.3, height: 0) + [[xb, z1, 0]], kind: :flush)
  far = curb.at(s1)[0]
  [[z0, near, -1], [z1, far, 1]].each do |z, xe, side|
    w6 = z + side * 0.5
    sc.surface([[xt, z, CH], [xe, z, CH], [xe, w6, CH], [xt, w6, CH]], kind: :curbtop)
    sc.wall([[xt, z, CH], [xb, z, 0], [xe, z, 0], [xe, z, CH]])
  end
  sc.clear([[xb, z0, 0], [xb, z1, 0], [xb + 4, z1, 0], [xb + 4, z0, 0]])
  if type == "422d"
    sc.warning(wd) { |u, v| [xb + v, z1 - u, 0] }
  else
    curb_warning(sc, curb, s0, s1, sides: [[[0, z0], [1, 0]], [[0, z1], [1, 0]]])
  end
  sc.joint([xt, z0, CH], [xt, z1, CH])
  sc.joint([xb, z0, 0], [xb, z1, 0])
  sc.edge(curb)
end

def build_422f(sc)
  r = 16.0
  curb = Curb.corner(r)
  a = 45 * Math::PI / 180
  apex = [-r + r * Math.cos(-a), r + r * Math.sin(-a)]
  d = unit([-1, 1])
  bc = add(apex, mul(d, 0.25))
  n = [d[1], -d[0]]
  curb.dip(curb.hit(add(bc, mul(n, -2.5)), mul(d, -1)), curb.hit(add(bc, mul(n, 2.5)), mul(d, -1)), 6.0, 6.0)
  corner_ground(sc, curb, r) do
    sc.crosswalk([apex[0], 0], [1, 0], [0, -1])
    sc.crosswalk([0, apex[1]], [0, 1], [1, 0])
    sc.faint([0, -1, 0], [0, -40, 0]) # face of curb extended
    sc.faint([1, 0, 0], [40, 0, 0])
  end
  ramp(sc, curb, bc, d, wings: [6.0, 6.0], warn: :ramp, clear: [5.0, 4.0])
  sc.edge(curb)
end

def build_422g(sc)
  r, band = 20.0, 10.0 # 6" at 5% max
  curb = Curb.corner(r)
  s0, s1 = curb.hit([-r, 1], [0, -1]), curb.hit([-1, r], [1, 0])
  curb.dip(s0, s1, 5.0, 5.0)
  c = [-r, r]
  corner_ground(sc, curb, r, inner: [-18, 18]) do
    sc.crosswalk([-r + 8, 0], [1, 0], [0, -1])
    sc.crosswalk([0, r - 8], [0, 1], [1, 0])
  end
  outer, inner = arc_pts(c, r, 0), arc_pts(c, r - band, CH)
  45.times { |i| sc.surface([outer[i], outer[i + 1], inner[i + 1], inner[i]], kind: :ramp, seam: true) }
  sc.brush((0..45).map { [outer[_1], inner[_1]] })
  sc.surface([[-r, 0, 0], [-r, band, CH], [-r - 5, 0, CH]], kind: :wing)
  sc.surface([[0, r, 0], [0, r + 5, CH], [-band, r, CH]], kind: :wing)
  curb_warning(sc, curb, s0, s1, rise: CH / band)
  sc.joint([-r - 5, 0, CH], *inner, [0, r + 5, CH])
  sc.edge(curb)
end

def build_422h(sc)
  hw, iz = 2.5, 3.0 # 5' path; 6' island = 2' panel + 2' gap + 2' panel
  sc.street
  sc.crosswalk([0, -iz], [1, 0], [0, -1])
  sc.crosswalk([0, iz], [1, 0], [0, 1])
  [-1, 1].each do |sx|
    a, b = sx * hw, sx * 40
    sc.wall([[a, -iz, 0], [b, -iz, 0], [b, -iz, CH], [a, -iz, CH]], context: true) # the island's own curbs
    sc.wall([[a, iz, 0], [b, iz, 0], [b, iz, CH], [a, iz, CH]], context: true)
    sc.wall([[a, -iz, 0], [a, iz, 0], [a, iz, CH], [a, -iz, CH]])
    sc.surface([[a, -iz, CH], [b, -iz, CH], [b, iz, CH], [a, iz, CH]], kind: :grass)
    sc.surface([[a, -iz, CH], [b, -iz, CH], [b, -iz + 1.0, CH], [a, -iz + 1.0, CH]], kind: :walk)
    sc.surface([[a, iz - 1.0, CH], [b, iz - 1.0, CH], [b, iz, CH], [a, iz, CH]], kind: :walk)
    sc.rim([a, -iz, CH], [b, -iz, CH], bright: true)
  end
  sc.surface([[-hw, -iz, 0], [hw, -iz, 0], [hw, iz, 0], [-hw, iz, 0]], kind: :flush)
  sc.warning(2 * hw) { |u, v| [-hw + u, -iz + v, 0] }
  sc.warning(2 * hw) { |u, v| [-hw + u, iz - 2 + v, 0] }
end

# ------------------------------------------------------------------ catalog

S = ->(a, b) { [a, b] } # a spec: headline, detail

# Families in the order the plans give them; each design is one drawing.
# view: the illustration's center (feet) and scale (units per foot); bounds:
# the 3D model's extent [x0, x1, z0, z1]; anchor: the model's origin.
DESIGNS = [
  { id: "422a", family: "422a", plan: 209, build: :build_422a,
    name: "Perpendicular ramp with wings", variant: "Wings",
    view: [[0, 5.5], 4.6], bounds: [-9.5, 9.5, 0, 12], anchor: [0, 0],
    when: "The usual corner ramp, where the sidewalk runs right up to the curb. Two per corner, one lined up with each crossing.",
    specs: [S["5 ft wide", "ramp (4 ft is the minimum)"], S["6 ft long", "rising 6 in at 8.3%, the steepest allowed"],
            S["5 ft wings", "on each side along the curb, at 10%"], S["4 ft landing", "level, at the top, as wide as the ramp"],
            S["2 ft yellow panel", "truncated domes across the full width, at the curb"],
            S["4 × 4 ft clear area", "on the street, inside the crosswalk"]] },
  { id: "422a-side-curbs", family: "422a", plan: 209, build: :build_422a_side_curbs,
    name: "Perpendicular ramp with side curbs", variant: "Side curbs",
    view: [[0, 5.5], 4.6], bounds: [-7, 7, 0, 14], anchor: [0, 0],
    when: "The same ramp where it crosses a grass planting strip: 6 in curbs hold back the grass instead of wings, so it takes less room along the curb.",
    specs: [S["5 ft wide", "ramp, the minimum with side curbs"], S["6 ft long", "rising 6 in at 8.3%, across the planting strip"],
            S["6 in side curbs", "level with the grass, on each side"], S["4 ft landing", "level, on the sidewalk, as wide as the ramp"],
            S["2 ft yellow panel", "across the full width, at the curb"], S["5 × 4 ft clear area", "on the street, inside the crosswalk"]] },
  { id: "422a-radius", family: "422a", plan: 209, build: :build_422a_radius,
    name: "Perpendicular ramps on a curved corner", variant: "Curved corner", radius: 25,
    view: [[-12, 9.5], 3.3], bounds: [-27, 0, 0, 27], anchor: [-7.32, 7.32],
    when: "Two of the same ramp on a rounded corner, one for each crossing, each set square to the curve of the curb. This is how most Seattle corners with a 422A ramp look.",
    specs: [S["Two ramps", "one lined up with each crosswalk"], S["Square to the curve", "each ramp's centerline points at the curve's center"],
            S["5 ft wide, 6 ft long", "at 8.3%, with 10% wings along the curve"], S["4 ft landings", "level, at the top of each ramp"],
            S["2 ft yellow panels", "at the curb on each ramp"], S["Curb in between", "full height, at least a foot between wings"]] },
  { id: "422b", family: "422b", plan: 210, build: :build_422b,
    name: "Parallel ramp", variant: "Sidewalk at the curb",
    view: [[0, 4.5], 4.4], bounds: [-12.5, 12.5, 0, 8.5], anchor: [0, 0],
    when: "For sidewalks too narrow to fit a ramp and a landing. The sidewalk itself dips along the curb to a landing at street level, then rises again, so people walking past go down and up too.",
    specs: [S["6 ft wide", "runs, the full sidewalk width (5 ft is the minimum)"], S["Two 6 ft runs", "along the curb, each dropping 6 in at 8.3%"],
            S["5 ft landing", "at street level between the runs (the minimum)"], S["4 ft at the top", "of full-width level sidewalk past each run"],
            S["2 ft yellow panel", "across the landing at the street edge"], S["6 in back curb", "behind the ramps, holding back the landscape"]] },
  { id: "422b-strip", family: "422b", plan: 210, build: :build_422b_strip,
    name: "Parallel ramp behind a planting strip", variant: "Planting strip",
    view: [[0, 6.5], 4.0], bounds: [-12.5, 12.5, 0, 13.5], anchor: [0, 0],
    when: "The same parallel ramp where the sidewalk sits behind a planting strip: the landing reaches through the strip to the curb between side curbs.",
    specs: [S["Two 6 ft runs", "along the sidewalk, each dropping 6 in at 8.3%"], S["5 ft landing", "at street level, from the back curb to the street"],
            S["Side curbs", "on both sides of the landing, through the planting strip"], S["4 ft at the top", "of full-width level sidewalk past each run"],
            S["2 ft yellow panel", "across the landing at the curb"], S["6 in back curb", "behind the ramps"]] },
  { id: "422c", family: "422c", plan: 211, build: :build_422c,
    name: "Parallel ramps at the corner", variant: "Curved landing", radius: 12,
    view: [[-8, 8], 3.5], bounds: [-20, 0, 0, 20], anchor: [-3.51, 3.51],
    when: "Parallel runs from both streets meet at one landing that wraps around the curb, at street level, serving both crossings.",
    specs: [S["Two runs", "6 ft wide (5 ft minimum) at 8.3%, one along each street"], S["Curved landing", "at street level around the corner"],
            S["5 × 5 ft turning space", "at least, on the landing"], S["Curved back curb", "behind the landing, with landscape inside"],
            S["Yellow panels", "in curved tile at each crossing"], S["5 ft route", "from the landing to each crosswalk (4 ft minimum)"]] },
  { id: "422c-square", family: "422c", plan: 211, build: :build_422c_square,
    name: "Parallel ramps at a square corner landing", variant: "Square landing", radius: 15,
    view: [[-9, 9], 3.4], bounds: [-20, 0, 0, 20], anchor: [-4.39, 4.39],
    when: "Sidewalks set behind planting strips run down to a square landing where they meet, and the corner is paved flush with the street out to the curb.",
    specs: [S["Two runs", "in each sidewalk, at 8.3%"], S["Square landing", "where the sidewalks meet, at street level"],
            S["5 × 5 ft turning space", "at least"], S["Paved to the curb", "flush with the street, 2% max"],
            S["Yellow panel", "in curved tile along the curb"], S["Side curbs", "where the landing meets the planting strips"]] },
  { id: "422d", family: "422d", plan: 212, build: ->(sc) { build_directional(sc, "422d") },
    name: "Directional ramp with wings", variant: "Wings", radius: 30,
    view: [[-13, 10], 3.3], bounds: [-24, 0, 0, 24], anchor: [-12, 6.0],
    when: "A ramp set on the curve of the corner but aimed straight along the crosswalk, so people roll out in the right direction.",
    specs: [S["Aimed along the crosswalk", "not square to the curb"], S["5 ft wide, 6 ft long", "at 8.3%"],
            S["5 ft or less", "from the bottom of the ramp to the curb"], S["Yellow panel", "at the bottom of the ramp"],
            S["4 ft clear area", "beyond the bottom of the ramp"], S["Wings at 10%", "the open-side wing at least 5%, a cue for blind pedestrians"]] },
  { id: "422d-side-curbs", family: "422d", plan: 212, build: ->(sc) { build_directional_side(sc, "422d") },
    name: "Directional ramp with side curbs", variant: "Side curbs", radius: 30,
    view: [[-13, 9], 3.6], bounds: [-28, 0, 0, 16], anchor: [-12, 8.5],
    when: "Where the sidewalk runs straight into the curve of the corner between planting strips: the sidewalk slopes down between side curbs, aimed along the crosswalk across the other street.",
    specs: [S["As wide as the sidewalk", "5 ft minimum"], S["6 ft long", "at 8.3%, between side curbs"],
            S["5 ft or less", "from the bottom of the ramp to the curb"], S["Yellow panel", "at the bottom of the ramp"],
            S["4 ft clear area", "beyond the bottom of the ramp"], S["Level apron", "out to the curb, 5% max"]] },
  { id: "422e", family: "422e", plan: 213, build: ->(sc) { build_directional(sc, "422e") },
    name: "Directional ramp, set back, with wings", variant: "Wings", radius: 30,
    view: [[-13, 10], 3.3], bounds: [-24, 0, 0, 24], anchor: [-12, 6.0],
    when: "The same directional ramp sitting more than 5 ft back from the curb. Seattle doesn't prefer it, but allows it where the corner leaves no other room.",
    specs: [S["More than 5 ft", "from the bottom of the ramp to the curb"], S["Yellow panel", "moves to the back of the curb, in curved tile"],
            S["2 ft at least", "between the ramp and the panel"], S["Level area", "between the ramp and the curb, 2% max"],
            S["4 ft clear area", "beyond the bottom of the ramp"], S["Wings at 10%", "on both sides"]] },
  { id: "422e-side-curbs", family: "422e", plan: 213, build: ->(sc) { build_directional_side(sc, "422e") },
    name: "Directional ramp, set back, with side curbs", variant: "Side curbs", radius: 30,
    view: [[-14, 9], 3.4], bounds: [-30, 0, 0, 16], anchor: [-12, 8.5],
    when: "The side-curb version, where the sidewalk runs into the curve between planting strips and stops more than 5 ft short of the curb.",
    specs: [S["As wide as the sidewalk", "5 ft minimum"], S["More than 5 ft", "from the bottom of the ramp to the curb"],
            S["Yellow panel", "at the back of the curb, in curved tile"], S["2 ft at least", "between the ramp and the panel"],
            S["4 ft clear area", "beyond the bottom of the ramp"], S["Side curbs", "on both sides, through the planting strips"]] },
  { id: "422f", family: "422f", plan: 214, build: :build_422f,
    name: "Shared diagonal ramp", variant: nil, radius: 16,
    view: [[-7, 6.5], 3.9], bounds: [-20, 0, 0, 20], anchor: [-4.69, 4.69],
    when: "One ramp at the apex of the corner for both crossings. Seattle builds it only when no two-ramp design can be built (Plan 422k).",
    specs: [S["At the apex", "square to the curb"], S["5 ft wide, 6 ft long", "at 8.3%, wings at 10%"],
            S["Yellow panel", "within 8 in of the curb"], S["5 × 4 ft clear area", "inside both crosswalks"],
            S["Behind both curb lines", "the clear area can't stick out into either street"], S["4 ft landing", "at the top"]] },
  { id: "422g", family: "422g", plan: 215, build: :build_422g,
    name: "Blended transition", variant: nil, radius: 20,
    view: [[-10, 9], 3.4], bounds: [-27, 0, 0, 27], anchor: [-5.86, 5.86],
    when: "The whole corner sidewalk slopes gently down to street level, with no ramp edges at all.",
    specs: [S["5% at most", "running slope (4.5% preferred), 2% cross slope"], S["The whole corner", "flush with the street at the curb"],
            S["Level bypass", "at the top, 6 ft wide (4 ft minimum)"], S["Yellow panel", "along the whole curb, in curved tile"],
            S["Wings at 10%", "where it meets the regular curb"], S["Two crossings", "served by one transition"]] },
  { id: "422h", family: "422h", plan: 216, build: :build_422h,
    name: "Island cut-through", variant: nil,
    view: [[0, 1], 4.4], bounds: [-10, 10, -3, 3], anchor: [0, -3],
    when: "A street-level path through a traffic island or pedestrian refuge in the middle of a crossing.",
    specs: [S["5 ft wide", "at least, level with the street"], S["Two yellow panels", "2 ft deep, one at each edge of the island"],
            S["2 ft apart", "at least; narrower islands get no panels"], S["4 × 4 ft clear space", "for each crosswalk"]] },
].freeze

FAMILIES = {
  "422a" => "Perpendicular", "422b" => "Parallel", "422c" => "Parallel at the corner", "422d" => "Directional",
  "422e" => "Directional, set back", "422f" => "Shared diagonal", "422g" => "Blended transition", "422h" => "Island cut-through",
}.freeze

def design_scene(design)
  sc = Scene.new
  b = design[:build]
  b.is_a?(Proc) ? b.call(sc) : send(b, sc)
  sc
end

def caveat(design)
  return unless design[:radius]

  "Drawn for a #{design[:radius]} ft curb radius. Real corners curve more or less than this, so the curb won't line up everywhere: line up the ramp itself."
end
