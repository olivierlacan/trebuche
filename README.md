# trebuche

Finding missing curb ramps, corner by corner, and helping neighbors ask the city to build
them. Streets so far, all in Seattle: **Dayton Ave N** (Phinney Ridge, where it started),
**2nd Ave NW** (Fremont), **9th Ave NW** (Whittier Heights), **30th Ave NW** (Loyal Heights)
and **Latona Ave NE** (Green Lake), plus a citywide **hotspot map** of where missing ramps cluster.

**Website:** <https://olivierlacan.github.io/trebuche/> (see [Publishing](#publishing)).

```
ruby scripts/fetch.rb      # download every street's sources into data/raw/<area>/  (a few min)
ruby scripts/build.rb      # write output/<area>/, each street's pages and data, docs/areas.js
ruby scripts/hotspots.rb   # citywide scan -> docs/seattle/hotspots/data.js
open docs/index.html       # every page also works straight from disk
```

Ruby 3.3+, standard library only, no gems. `ruby scripts/fetch.rb city` (or `ps`,
`osm`) refreshes a single source; `ruby scripts/fetch.rb fremont` (or `build.rb fremont`)
a single street.

## Streets

Each street is one entry in `data/areas.json`: its neighborhood and URL slug, the OSM
names of the street and its numbered cross streets (`"cross_prefix": "Northwest"`), the
range of cross streets, a corner ID prefix (`dayton` makes `dayton-61-NE`), the download
box and a narrow OSM corridor. `build.rb` renders each street's `index.html` and
`map.html` from `templates/area/*.erb`, so edit the templates, not the generated pages.
The pipeline handles north–south streets crossed by numbered streets, including jogs in
the main street (`64W`/`64E`) and side streets that don't line up across it (`82S`/`82N`,
two T-intersections).

## Hotspots

`scripts/hotspots.rb` checks every SDOT intersection in Seattle (about 13,000) against
SDOT's curb ramp inventory, SDOT's sidewalk inventory and Project Sidewalk's
per-intersection scores. An intersection counts as **no ramp** when SDOT has no built ramp
there and either SDOT recorded "no ramp" or volunteers labeled a missing ramp and no ramps.
Only intersections with an improved sidewalk count (`SURFTYPE` other than `UIMPRV`), so
places without sidewalks at all don't show up as ramp hotspots. Intersections are grouped
into ~450 m cells; cells with 6 or more no-ramp intersections are hot, and side-by-side hot
cells merge into a hotspot named after the city's Community Reporting Areas and council
districts. `docs/seattle/hotspots/` shows the map, the ranked hotspots (`?spot=3` links to
one), and a table by neighborhood with survey coverage. Downloads are cached in
`data/raw/citywide/`; `--refresh` downloads again (the daily build does).

## Outputs

| File | What |
|---|---|
| `docs/` | The website (see below). Generated: `areas.js`, each street's `index.html`, `map.html`, `data.js` and `corners.csv`, `seattle/hotspots/data.js`; `og.png` images rendered by hand |
| `output/<area>/corners.csv` | One row per corner: overall status, which crossings lack a ramp, per-source verdicts, city install date, SDOT work orders, evidence IDs (not committed; the same CSV is published with each street's pages) |
| `output/<area>/corners.geojson` | Same rows as points |

## The website

| Page | File | What |
|---|---|---|
| Home | `docs/index.html` | The project, not tied to a place: what it does, how it works, how sure "missing" is, how to start a street, and a card per street |
| Why ramps matter | `docs/why/index.html` | Why curb ramps matter and who uses them, with to-scale drawings: a wheelchair at a bare curb vs. a ramp, common wheel sizes against a 6 in curb, Seattle's armored curbs (with the 1919 Standard Plans' "Curb Armor" and "Concrete Curbing" drawings, `docs/why/1919-*.png`, cropped from the city's scan), the detour when only one side of a crossing has a ramp, and podcasts, video and books to go further. Hand-written, with inline SVG |
| Seattle | `docs/seattle/index.html` | How to ask Seattle for a ramp, what Seattle's data gets wrong, other Seattle tools, and Seattle's streets |
| Hotspots | `docs/seattle/hotspots/index.html` | Citywide map and ranking of where missing ramps cluster, and how to organize |
| A street | `docs/seattle/<neighborhood>/index.html` | e.g. Phinney Ridge for Dayton Ave N: live counts, the corner strip, goals, how to help |
| Its map | `docs/seattle/<neighborhood>/map.html` | The street's map (below) |

Screenshots of pages, used in pull requests, live in `screenshots/` (outside `docs/`, so they aren't deployed). Keep them about 1200 px wide.

Shared files live at the top of `docs/`: `logo.svg`, `site.css` (text pages), `style.css`
and `app.js` (map), `area.js` (a street's landing page), `area-cards.js` (street cards,
drawn from the generated `areas.js`). The street pages read their own `data.js`.

Old links keep working: `/?corner=…` and `/map.html?corner=…` (from before the site had
sections) forward to the Dayton Ave N map with the same parameters.

**Street landing page:** what the effort is for and its goals, live counts of missing and
partial corners, a strip showing every corner from 60th to 85th (each links into the map),
how neighbors can help, and why the site combines three sources. Its numbers come from the
same `data.js` as the map, so they update with the daily refresh.

**Map:** a static Leaflet map plus a side panel (below the map on phones):

- **Key:** what the markers mean, and layer toggles.
- **Corner:** everything known about one corner, with **Copy request text** (location,
  which crossing lacks a ramp, the evidence, and a link back to the corner), links to the
  right city form, and **I filed this**.
- **How to request:** who can use which city channel (below).
- **Checks:** corners you've checked in person (below), and a button to send them.
- **Group:** pick corners. The page splits them into packets of at most two intersections
  (SDOT's limit per form), drafts a neighborhood letter, and gives one link to the whole
  selection.
- **All corners:** every corner as a list, south to north. It doubles as a non-map way to
  browse.

The **locate button** (under the zoom buttons) uses the browser's GPS to show your
position, keep the map centered on you, and name the nearest Dayton corner with a link
to open it. It only asks for location when tapped. Your position is never stored or
sent anywhere, and it stays out of the address bar while the map follows you. Dragging
the map stops following; tapping the button again stops location entirely.

The map zooms to level 21. OSM tiles stop at 19 and are scaled up past that, which is
enough to pick out a single curb. Corner markers sit at the average of the mapped curb
points (SDOT ramp records and OSM kerb nodes) for that corner, so they land on the curb.

### Links you can share

Start from what the hotspot map shows, not from any one corner: `seattle/hotspots/?spot=1`
opens Seattle's largest cluster of missing ramps (Fremont / Greenwood / Phinney Ridge),
and Dayton Ave N runs through it. The examples below stay inside that hotspot: at Dayton
& N 61st St, all four corners are confirmed missing.

| Parameter | Example | Effect |
|---|---|---|
| `corner` | `seattle/phinney-ridge/map.html?corner=61-NE` | Opens that corner and zooms to it |
| `lat`, `lng`, `z` | `?lat=47.66683&lng=-122.35565&z=16` | Map center and zoom (1–21); this one is the hotspot's center |
| `sel` | `?sel=79-NE,79-NW,64W-SW` | Corners in the group request |
| `tab` | `?tab=group` | Which panel is open: `key`, `corner`, `request`, `group`, `list` |

The address bar updates as you pan, zoom and select, so copying it shares exactly what
you're looking at. Corner IDs are the `corner_id` column without the `dayton-` prefix.

### Reading the map

Color shows **when SDOT installed the ramp**, so install campaigns show up as patches
of one color. Ramps installed in the last month are **green**; the color shades
through **yellow** at one year old to **brown** for the oldest installs (2008). Gray
means SDOT has no install date, which is true for more than half of the ramps.

| Marker | Meaning |
|---|---|
| filled circle | Corner has a ramp for both crossings (colored by install date) |
| circle with small × | Ramp for one crossing only. The other crossing still has no ramp |
| black **X** | No ramp, and at least two sources agree |
| **?** | Not sure: only one source says missing, sources conflict, or no data |
| purple dashed ring | SDOT has an open work order here (planned construction or a resident request) |
| pink ring | SDOT work whose dates overlap the current week (opened on or before this week, estimated done this week or later), or that closed this week |
| green dot | A neighbor has filed a request (from `data/requests.csv`) |
| orange check | Someone checked this corner in person (from `data/field-checks.csv`, or your own unsent checks) |
| blue box | Corner is in your group request |
| small dots / rings | Every SDOT ramp nearby by install date, and SDOT work orders away from Dayton |

Planned vs. ongoing is worked out in the browser against the viewer's current week, so
the map stays right between data refreshes. As of the 2026-11-01 data nothing is pink:
every open work order's estimated completion date is already in the past (the latest is
2026-04-08), or it has none.

### How neighbors file requests

Checked against seattle.gov on 2026-11-01:

- **People with a disability, or who directly care for someone who does:** SDOT's
  [Curb Ramp Request form](https://forms.office.com/g/R2d2GXDbXu), from the
  [Make an ADA Infrastructure Request](https://www.seattle.gov/transportation/projects-and-programs/programs/ada-program/make-an-ada-request)
  page. Each form covers at most two intersections, and there's no limit on the number
  of forms. SDOT responds within 15 days of verifying a request and sends preliminary
  scoping within 30. The program is limited to disability access, so the site doesn't
  steer stroller-only requests to it.
- **Everyone else:** the Customer Service Bureau. Use
  [Find It, Fix It](https://www.seattle.gov/customer-service-bureau/find-it-fix-it-mobile-app)'s
  "General Inquiry" category (there's no curb ramp category) or the
  [web portal](https://seattle-cwiprod.motorolasolutions.com/).
- **As a group:** split packets between eligible neighbors, send the drafted letter to
  your councilmember and SDOT, and comment at SDOT's Pedestrian Access Advisory
  Committee or the Seattle Pedestrian Advisory Board. Ramps at 64th are already
  in SDOT's "2023 PEMS DWW ramps on-hold" project, so the letter asks for it to be
  restarted. (79th was in it too; a neighbor found its ramps built in November 2026.)

**I filed this** opens a prefilled GitHub issue (corner IDs, channel, date, tracking
number) so the group can see what's been filed. It asks people not to post contact
details. Copy filed requests into `data/requests.csv` to show them on the map.

## Logo

`ruby scripts/logo.rb` draws the logo: a City of Seattle Type 422A curb ramp seen from
above at a slight angle, leading to a crosswalk. Every proportion comes from the 2026
City of Seattle Standard Plans and Specifications (Seattle Public Utilities and SDOT):

- **422a:** 5 ft ramp, triangular wings, through joints along the wings and across the
  top, 4 ft landing (outlined by through joints)
- **422k:** 2 ft yellow detectable-warning panel, truncated domes in an in-line grid
- **420 / Spec 8-14.3:** 2 ft scoring (drawn faint), contraction joints about 6 ft apart
  (the spec allows up to 15 ft), 6 ft minimum sidewalk, planting strip beyond
- **712:** "ladder style" crosswalk (`XWK`): pairs of 8 in bars with an 8 in gap,
  parallel to the curb, 5 ft apart, centered on the ramp

It writes two drawings, the way app icons are made per size:

| File | Use |
|---|---|
| `docs/logo.svg` | Detailed: page headers, link previews |
| `docs/favicon.svg` | Simplified for 16–32 px: browser tabs (tighter crop, more contrast, no texture) |

`ruby scripts/logo.rb --bleed out.svg` writes a version without the rounded outline,
used to render `docs/apple-touch-icon.png` (phones apply their own mask). The link
preview images (`docs/og.png`, `docs/seattle/phinney-ridge/og.png`) are rendered from
`logo.svg`. The previous street-level logo is kept as `docs/logo-street.svg`.

## Curb ramp designs

Seattle's 2026 Standard Plans have eight curb ramp types (422a–422h), most drawn more than
one way. Trebuche treats each drawing as a design, 14 in all:

| Type | Designs (ID) |
|---|---|
| 422A perpendicular | with wings (`422a`), with side curbs across a planting strip (`422a-side-curbs`), two ramps radial to a curved corner, from the sheet's location inset (`422a-radius`) |
| 422B parallel | sidewalk at the curb (`422b`), behind a planting strip (`422b-strip`) |
| 422C parallel at the corner | curved landing (`422c`), square landing (`422c-square`) |
| 422D directional | with wings (`422d`), with side curbs where the sidewalk runs into the curve (`422d-side-curbs`) |
| 422E directional, set back | with wings (`422e`), with side curbs (`422e-side-curbs`) |
| 422F shared diagonal, 422G blended transition, 422H island cut-through | `422f`, `422g`, `422h` |

Not included: 456b (temporary ramps for construction detours) and 433 (a waste access
ramp, not for pedestrians).

`scripts/ramp_designs.rb` describes every design once: plan geometry in feet (surfaces in
drawing order, curb faces and walls, warning panels, joints, clear areas, crosswalks) and
the words for it (when the city uses it, key dimensions, plan sheet, and a caveat for
corner designs, which are drawn on one curb radius each: 12 ft for 422C, 15 ft for the
square 422C, 16 ft for 422F, 20 ft for 422G, 25 ft for the curved 422A, 30 ft for 422D/E).
Two scripts read it:

- `ruby scripts/catalog.rb` draws the illustrations, `docs/seattle/curb-ramps/<id>.svg`, in
  the logo's style. They're to scale in plan, with the curb drawn about 2.6 times its real
  height as in the logo, and broom finishes in the direction each sheet gives. It also
  writes the catalog page (`docs/seattle/curb-ramps/index.html`, from
  `templates/curb-ramps/index.html.erb`) and `docs/ar/designs.js` for the AR page. Pass IDs
  to redraw just those illustrations.
- `ruby scripts/ramp_model.rb` builds the 3D models (below).

## Curb ramp in AR

`docs/ar/` shows any of the 14 designs at true scale, for neighbors to place at a corner
with their phone as a rough check of what fits (poles, hydrants, drains, planting strips).
It uses Google's open-source [`<model-viewer>`](https://modelviewer.dev/): Chrome's AR on
Android, AR Quick Look on iPhone and iPad, and a 3D view everywhere else. Scale is locked
to true size. People pick a type (with its illustration as the thumbnail), then a
version; `?type=<id>` opens a design directly, so older links (`422a`, `422a-side-curbs`,
`422b`) still work. Corner designs show their curb radius caveat.

`ruby scripts/ramp_model.rb` writes `docs/ar/ramp-<id>.glb` (binary glTF, in meters,
standard library only). The designs are described the way they're drawn, later surfaces
on top, so the script cuts each surface wherever a later one covers it in plan, adds the
vertical faces (curb faces, side and back curbs, the slab's cut edges), and puts truncated
domes at their real size and spacing (422k) on every warning panel. Only what would be
built goes in: the illustrations' grass, existing sidewalk, full-height curb, street and
crosswalks are left out so they don't hide the real ground, and a thin white line marks
where the real curb's top edge should line up. `--check` prints each
model's footprint and dome count. Every file passes the Khronos glTF validator with no
issues.

The page turns each model 180° (`orientation`) so AR sets it down with its street side
away from you, and the 3D preview shows it from the sidewalk the way you'll see it. AR
places models level, so the page has two slope sliders (along the curb, toward the
street; `?grade=4&cross=-2` in percent) that tilt the model before AR opens: model-viewer
builds the iPhone's USDZ from the live scene, tilt included, and WebXR on Android uses it
directly. On phones, a button measures the grade along the curb from the phone lying flat
on the sidewalk (DeviceOrientation, with iOS's permission prompt). Phone AR can't use the
wide-angle camera, so the page tells people to place the model from a few steps back and
walk back to see all of it.

Corners that need a ramp link to it from the map (`ar/?corner=61-NE` names the corner and
links back). The page tells people to stay on the sidewalk, and says plainly that it's a
visual aid: phone AR drifts a few percent and assumes flat ground, and SDOT engineers
choose the actual design.

## Accessibility

A site about accessibility has to be accessible. The target is WCAG 2.2 AA.
`node scripts/a11y-scan.js` runs axe-core over every page and the map's interactive states,
in light and dark mode, at desktop and phone widths (setup is at the top of the script).
Beyond what axe checks automatically:

- **Keyboard:** map markers are buttons (Tab, then Enter or Space). A skip link jumps past
  the map. The panel tabs follow the ARIA tabs pattern with arrow keys. The hotspot table
  sorts with real buttons.
- **Targets:** links and controls are at least 24 px. Map markers that overlap when zoomed
  out are covered by WCAG 2.5.8's "equivalent" exception: every corner is also a button
  under "All corners", and every hotspot has a card.
- **Not color alone:** missing ramps are black X marks, unknowns are question marks, and
  partial corners carry a small X.
- **Other:** visible 3 px focus rings everywhere, reflow at 320 px with no sideways
  scrolling, and smooth scrolling turned off under `prefers-reduced-motion`.

## Publishing

`.github/workflows/pages.yml` refetches every source, rebuilds, and deploys `docs/` to
GitHub Pages. It runs on every push to `master`, daily at about 3:23 am Seattle time,
and on demand from the Actions tab. One-time setup: in the repository's **Settings →
Pages**, set **Source** to **GitHub Actions**.

The daily run means a pink "ongoing" ring can appear as soon as SDOT dates new work.
The committed `docs/seattle/phinney-ridge/data.js` is only a snapshot for local use; the published site always
uses freshly fetched data. If a source is down, that day's deploy fails and the previous
version stays up.

## Data sources

| Source | Endpoint | Notes |
|---|---|---|
| SDOT Curb Ramps (Active) | `services.arcgis.com/ZOyb2t4B0UYuYNYH/.../Curb_Ramps_(Active)/FeatureServer/0` | One point per ramp. `CATEGORY` SINGLE/SHARED/NORAMP, `DIRECTION`, `INSTALL_DATE`, `CONDITION` |
| SDOT Curb Ramp Work Orders | `.../Curb_Ramp_Work_Orders/FeatureServer/0` | Used to flag ramps SDOT has already planned. The free-text `WORKDESC` field is **not** downloaded: it can contain residents' contact details |
| Project Sidewalk Seattle | `sidewalk-sea.cs.washington.edu/v3/api/rawLabels?bbox=…` | Crowdsourced `CurbRamp` / `NoCurbRamp` labels from street-view imagery. Labels validators marked incorrect are dropped |
| OpenStreetMap | Overpass (`overpass-api.de`, then `maps.mail.ru` mirror), falling back to the OSM API `map` call tiled along a narrow corridor | `kerb=lowered/flush/no` = ramp, `kerb=raised/regular` = no ramp |

## Method

**Intersections** come from OSM street geometry. Many Dayton intersections have traffic
circles, where the street ways stop short of the center, so intersections are found
by latitude rather than shared nodes.

Dayton **jogs** at 64th and 65th. A jog is where a street doesn't continue straight
through an intersection: Dayton south of 64th is about 35 m west of Dayton north of
64th, so you turn onto 64th for a few seconds to keep going north on Dayton. The same
thing happens again, offset about 20 m, at 65th. Each jog is two T-intersections
(`64W`/`64E`, `65W`/`65E`). The side of a T with no street still gets a marker, called a
"T-intersection landing", because it only needs the ramp for crossing Dayton.

**Per-crossing coverage.** A full corner needs two ramps: one for crossing Dayton
(`main`) and one for crossing the side street (`cross`). A SHARED (diagonal) ramp
covers both.

- **City:** SINGLE ramps cover the crossing their `DIRECTION` points along. City records
  with blank category, zero width and no assessment are listed as `unassessed`, and
  don't count as ramps. At Dayton they're all tied to the open, on-hold SDOT work-order
  group "2023 PEMS DWW ramps on-hold", which means planned but not built.
- **OSM:** the crossing direction comes from the bearing of the `footway=crossing` way
  each kerb node sits on. An unmapped kerb isn't evidence of anything. If only some of a
  corner's crossings are mapped, OSM reports `ramp (partly mapped)` and doesn't vote.
- **Project Sidewalk:** labels carry no reliable direction, so a corner with both
  `CurbRamp` and `NoCurbRamp` labels is `partial`.

**Combining.** If all voting sources agree, that's the result. If they disagree and the
city's latest install/verify date is newer than the other sources' observations
(Project Sidewalk imagery date, OSM last edit), the city wins and the row is still
flagged `sources_disagree`. If every source says something is lacking but they disagree
on how much, the result is `partial`. Anything else is `conflict`.

**Confirmed missing** (black X) means at least two sources independently say there's no
ramp. SDOT has no explicit `NORAMP` records on Dayton, so in practice that's Project
Sidewalk plus OSM.

**Matching.** Evidence within 30 m of an intersection center is assigned to the nearest
intersection, then to a quadrant.

### Caveats

- Project Sidewalk imagery along Dayton is mostly 2018–2022, so it misses recent SDOT
  work (e.g. 63rd St, built Aug 2026).
- SDOT `no record` is not the same as "missing". But at 60th–62nd, 65th, 70th and
  72nd–77th, Project Sidewalk and OSM both independently say no ramps.
- Each corner is placed 9 m diagonally from the intersection center for display.
  Positions are approximate.
- Before filing a request, check conflicts and partials on the ground (or in Street View).

## Checking corners in person

The sources can be years out of date, so the map lets neighbors record what they see.
Reports go one corner at a time, the corner open in the panel. Under its status, **Report
what's here** opens a short checklist for that corner: **No ramp to cross** each street
it needs a ramp for, **Central ramp facing the middle of the intersection** (one ramp at
the apex instead of one lined up with each crosswalk), **No yellow pad**, **Older
crisscross style**, **Cracked or uneven** and **Lip at street edge**, each with a small
drawing of what to look for (the missing-ramp and central-ramp ones are turned to match
the corner). Each tick is
saved right away. **Nothing wrong here** records
a good corner in one tap, and **Same as NW** (the last corner reported at that
intersection) copies it, so Dayton & N 83rd St, where all four corners have the same
older ramps, is one corner's ticks and then three taps. A small plan of the intersection
shows what's been reported (yellow ramp: with a pad, gray: without, ✕: no ramp) and
outlines the open corner; tapping another corner, or a **Next** link, opens it. A note
per corner covers anything else.
There's no server: checks
are saved in the browser (`localStorage`, key `trebuche:checks`, shared by every
street's map) and the corners are redrawn right away for that visitor, with an orange
check. With location on (the locate button), the panel says whether the phone is at the
intersection on screen, offers to switch if it's at a different one, opens the report
when you reach the open corner, and each check
records how far the phone was from its corner and how precise the fix was (never the
position itself). A whole walk can go out at once from the **Checks** tab, which opens
the `.github/ISSUE_TEMPLATE/field-check.yml` issue form (label `field-check`) with every
field filled in from query parameters (`template=field-check.yml&summary=…&rows=…&map=…`):
one line per intersection ("ramps both ways at all 4 corners (phone location on site)"),
a Photos field to drag pictures into (GitHub hosts them; a link can't attach files, so
this is the one manual step), and the rows as CSV. If the link would
be too long for GitHub, the rows go on the clipboard to paste instead. **Copy as CSV**
is there for people without a GitHub account.

To publish them, paste the rows into `data/field-checks.csv` and push:

```
corner_id,date_checked,ramps_for,yellow_pad,ramp_issues,notes,distance_ft,accuracy_ft
dayton-80-NE,2026-11-07,main+cross,yes,,,15,20
dayton-83-NW,2026-11-07,cross,no,old_style,,,
```

`ramps_for` names the crossings that had a ramp: `main` (crossing the main street),
`cross` (crossing the side street), `main+cross`, or `none`. The latest check for a
corner wins over every other source and sets `overall` (a check that finds no ramp
counts as confirmed missing), unless SDOT recorded work there after the check.
`yellow_pad` is `yes`, `no` or blank (not noted). `ramp_issues` lists anything else
wrong with the ramps, joined with `+`: `diagonal` (one central ramp at the apex, aimed at
the middle of the intersection instead of lined up with each crosswalk, like Standard Plan
422F; it still counts as a ramp for the crossings it serves), `old_style` (crisscross
grooves), `damaged`, `lip`. A `no` pad (Standard Plan 422k requires one) or any issue makes the corner say **Needs upgrade**, and their
request text asks SDOT to upgrade the ramp as well as add any missing one.
`distance_ft` and `accuracy_ft` are blank for checks saved without location; the build
doesn't use them yet, they're there for whoever reviews the issue. The CSV
gains `field_*` columns. Once the published data has a check as new as a visitor's own,
the browser drops its copy.

## Tracking SDOT requests

Add a row to `data/requests.csv` when a neighbor files a request, then re-run
`build.rb` (or push, and the workflow rebuilds). The corner gets a green dot on the map,
and the CSV gains `request_*` columns.

```
corner_id,date_filed,sdot_reference,filed_by,status,notes
dayton-61-NE,2026-11-05,Find It Fix It #12345678,,submitted,
```

`corner_id` values come from `output/corners.csv`. Avoid putting names or contact
details in `filed_by` if this repo is public. See
[How neighbors file requests](#how-neighbors-file-requests) for the channels.
