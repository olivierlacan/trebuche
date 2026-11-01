# trebuche

Finding missing curb ramps along **Dayton Ave N, Seattle (N 60th – N 85th St, Phinney Ridge)**
so neighbors can file SDOT curb ramp requests, starting with stroller access.

```
ruby scripts/fetch.rb    # download all sources into data/raw/  (~1 min)
ruby scripts/build.rb    # write output/corners.csv, corners.geojson, map.html
open output/map.html
```

Ruby 3.3+, standard library only, no gems. `ruby scripts/fetch.rb city` (or `ps`,
`osm`) refreshes a single source.

## Outputs

| File | What |
|---|---|
| `output/corners.csv` | One row per corner: overall status, per-source verdicts, city install date, evidence IDs |
| `output/corners.geojson` | Same rows as points |
| `output/map.html` | Self-contained Leaflet map (data embedded). Tap a marker for per-source detail |

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
| blue ring | An SDOT request has been filed (from `data/requests.csv`) |
| small dots | Every SDOT ramp in the area, by install date (can be turned off in the legend) |

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
`build.rb`. The corner shows a blue ring on the map, and the CSV gains
`request_*` columns.

```
corner_id,date_filed,sdot_reference,filed_by,status,notes
dayton-61-NE,2026-11-05,Find It Fix It #12345678,,submitted,
```

`corner_id` values come from `output/corners.csv`. Avoid putting names or contact
details in `filed_by` if this repo is public. Requests can go through SDOT's Curb Ramp
request form, Find It Fix It, or 684-ROAD.
