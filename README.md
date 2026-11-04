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
| Seattle | `docs/seattle/index.html` | How to ask Seattle for a ramp, what Seattle's data gets wrong, other Seattle tools, and Seattle's streets |
| Hotspots | `docs/seattle/hotspots/index.html` | Citywide map and ranking of where missing ramps cluster, and how to organize |
| A street | `docs/seattle/<neighborhood>/index.html` | e.g. Phinney Ridge for Dayton Ave N: live counts, the corner strip, goals, how to help |
| Its map | `docs/seattle/<neighborhood>/map.html` | The street's map (below) |

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

| Parameter | Example | Effect |
|---|---|---|
| `corner` | `seattle/phinney-ridge/map.html?corner=61-NE` | Opens that corner and zooms to it |
| `lat`, `lng`, `z` | `?lat=47.66683&lng=-122.35565&z=21` | Map center and zoom (1–21) |
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
  Committee or the Seattle Pedestrian Advisory Board. Ramps at 64th and 79th are already
  in SDOT's "2023 PEMS DWW ramps on-hold" project, so the letter asks for it to be
  restarted.

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

`docs/seattle/curb-ramps/` illustrates every curb ramp design in Seattle's 2026 Standard
Plans, in the logo's style: 422A (with wings, and with side curbs), 422B, 422C, 422D,
422E, 422F, 422G and 422H. Each card says when the city uses the design, lists its key
dimensions, and links to its plan sheet (and to AR for the three designs modeled there).

`ruby scripts/catalog.rb` draws the illustrations (`docs/seattle/curb-ramps/<type>.svg`,
standard library only; pass type IDs to redraw just those). They're to scale in plan, from
each sheet's dimensions, with the curb drawn about 2.6 times its real height as in the logo.
Corner designs use a curb radius that fits each one (12 ft for 422C, 16 ft for 422F,
20 ft for 422G, 30 ft for the directional ramps). Broom finishes follow each sheet:
parallel to the curb on 422A, perpendicular or radial on 422B, 422C and 422G.

## Curb ramp in AR

`docs/ar/` shows true-scale City of Seattle curb ramps that neighbors can place at a corner
with their phone, as a rough check of what fits (poles, hydrants, drains, planting strips).
It uses Google's open-source [`<model-viewer>`](https://modelviewer.dev/): Chrome's AR on
Android, AR Quick Look on iPhone and iPad, and a 3D view everywhere else. Scale is locked
to true size.

People pick one of three designs from the 2026 Standard Plans, all sized for Seattle's
6 in curb:

| Design | File | When | Model |
|---|---|---|---|
| 422A with wings | `ramp-422a.glb` | Sidewalk reaches the curb | 5 ft ramp rising over a 6 ft run (8.3%), 5 ft wings at 10%, 4 ft landing, 4 × 4 ft clear area |
| 422A with side curbs | `ramp-422a-side-curbs.glb` | Ramp crosses a planting strip | Same run between 6 in side curbs and grass, landing on a 6 ft sidewalk, 5 × 4 ft clear area |
| 422B parallel | `ramp-422b.glb` | Sidewalk too narrow for a ramp and landing | Two 6 ft wide runs along the curb down to a 5 ft landing at street level, 4 ft of level sidewalk past each, 6 in back curb |

Each has a 2 ft yellow warning panel with truncated domes at their real size and spacing
(422k) and through joints. `?type=422a-side-curbs` (or `422b`) opens a design directly.
The page also lists Seattle's other designs (422C–422H) and why they aren't in AR: they
wrap around the curb radius, which differs at every corner.

`ruby scripts/ramp_model.rb` writes the models (binary glTF, in meters, standard library
only). `--check` prints the dimensions measured from each mesh. The files pass the Khronos
glTF validator with no issues.

Corners that need a ramp link to it from the map (`ar/?corner=61-NE` names the corner and
links back). The page tells people to stay on the sidewalk, and says plainly that it's a
visual aid: phone AR drifts a few percent and assumes flat ground, and SDOT engineers
choose the actual design.

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
