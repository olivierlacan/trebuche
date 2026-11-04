#!/usr/bin/env ruby
# frozen_string_literal: true

# Draws the curb ramp design catalog from scripts/ramp_designs.rb: one
# illustration per design, in the style of the logo (scripts/logo.rb), seen
# from above at a slight angle, with warm concrete, yellow truncated-dome
# panels, recessed joints, broom finishes, ladder crosswalks and a fine grain.
# Every drawing is to scale in plan; like the logo, the curb is drawn about 2.6
# times taller than it is so the 6" curb reads at small sizes.
#
# Also writes the catalog page (from templates/curb-ramps/index.html.erb) and
# docs/ar/designs.js, the list of designs the AR page offers.
#
#   ruby scripts/catalog.rb              # everything
#   ruby scripts/catalog.rb 422g 422h    # just these illustrations (and the pages)

require "erb"
require "json"
require_relative "ramp_designs"

ROOT = File.expand_path("..", __dir__)
OUT = File.join(ROOT, "docs/seattle/curb-ramps")

LIFT = 2.6    # drawn height exaggeration (the logo draws its curb about 3x)
K    = 0.68   # foreshortening of depth, as in the logo
VW, VH = 160.0, 100.0

def f2(v) = format("%.2f", v)

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

  # The lit back edge of a sidewalk, or the street-side edge of an island.
  def rim(a, b, bright: false)
    @o << %(<path d="#{path([a, b], close: false)}" stroke="#fffdf6" stroke-opacity="#{bright ? 1 : 0.7}" stroke-width="#{f2(@s * (bright ? 0.14 : 0.1))}"/>)
  end

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


# Draws a design's scene, in order.
def illustrate(design)
  view_c, view_s = design[:view]
  art = Art.new(center: view_c, scale: view_s, label: "Type #{design[:id].upcase.sub(/-.*/, '')}: #{design[:name]}")
  design_scene(design).ops.each do |kind, args, kw, blk|
    case kind
    when :surface
      pts = args[0]
      case kw[:kind]
      when :grass then art.grass(pts)
      when :walk then art.concrete(pts)
      when :landing then art.fill(pts, Art::CONCRETE)
      when :curbtop then art.fill(pts, "#d8d0bd", kw[:seam] ? %( stroke="#d8d0bd" stroke-width="0.35") : "")
      when :flush then art.surface(pts, "#d9d2c1", seam: kw[:seam])
      else art.surface(pts, Art::RAMP, seam: kw[:seam])
      end
    when :wall then art.face(args[0])
    when :curb then art.curb_faces(args[0])
    when :edge then art.curb_edge(args[0])
    when :street then art.street
    when :crosswalk then art.crosswalk(*args, **kw)
    when :clear then art.clear_area(args[0])
    when :warning then art.warning(*args, &blk)
    when :joint then art.joint(*args, **kw)
    when :brush then art.brush(args[0])
    when :faint then art.faint(*args)
    when :rim then art.rim(*args, **kw)
    else raise "unknown op #{kind}"
    end
  end
  art
end

def alt_text(d) = "Illustration of a Seattle Type #{d[:id][0, 4].upcase} curb ramp (#{d[:name].downcase}), seen from above"

if $PROGRAM_NAME == __FILE__
  Dir.mkdir(OUT) unless Dir.exist?(OUT)
  only = ARGV.reject { _1.start_with?("-") }
  DESIGNS.each do |d|
    next unless only.empty? || only.include?(d[:id])

    File.write(File.join(OUT, "#{d[:id]}.svg"), illustrate(d).to_svg(alt_text(d)))
    puts "wrote docs/seattle/curb-ramps/#{d[:id]}.svg"
  end

  # The AR page's list of designs (same words as the catalog).
  list = DESIGNS.map do |d|
    { id: d[:id], family: d[:family], code: d[:id][0, 4].upcase, familyName: FAMILIES[d[:family]], name: d[:name],
      variant: d[:variant], plan: d[:plan], when: d[:when], specs: d[:specs], caveat: caveat(d), alt: alt_text(d) }
  end
  File.write(File.join(ROOT, "docs/ar/designs.js"),
             "// Generated by scripts/catalog.rb from scripts/ramp_designs.rb\nwindow.RAMP_DESIGNS = #{JSON.pretty_generate(list)};\n")
  puts "wrote docs/ar/designs.js"

  families = DESIGNS.group_by { _1[:family] }
  template = File.read(File.join(ROOT, "templates/curb-ramps/index.html.erb"), encoding: "UTF-8")
  html = ERB.new(template, trim_mode: "-").result_with_hash(families: families)
  File.write(File.join(OUT, "index.html"), html)
  puts "wrote docs/seattle/curb-ramps/index.html"
end
