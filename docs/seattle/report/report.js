/* Report a corner anywhere in Seattle. Intersections come from the hotspot scan
 * (../hotspots/data.js, window.HOTSPOTS: SDOT's intersection inventory); what a report
 * can say, and its icons, from ../../report-kit.js. Reports stay in this browser until
 * they're sent as a GitHub issue, then land in data/citywide-checks.csv. */
"use strict";

const H = window.HOTSPOTS;
const REPO = "olivierlacan/trebuche";
const KEY = "trebuche:citywide-checks";
const FT = 3.28084;
const ON_SITE_FT = 300;   // matches scripts/hotspots.rb
const SNAP_M = 80;        // a fix this close to an intersection opens it
const esc = s => String(s ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));

// [lat, lon, status (0 unknown, 1 ramps, 2 none), sidewalk, name, SDOT id, reported (0, 1 on site, 2 not)]
const PTS = H.points.filter(p => p[5] != null)
  .map(([lat, lon, st, sw, name, id, rep]) => ({ lat, lon, st, sw, name, id: String(id), rep: rep || 0 }));
const byId = new Map(PTS.map(p => [p.id, p]));
const STATUS = ["no record either way", "SDOT has recorded ramps", "no curb ramp on record"];

const CORNERS = ["NW", "NE", "SW", "SE"];
const CORNER_WORDS = { NE: "northeast", NW: "northwest", SE: "southeast", SW: "southwest" };
const OPP = { N: "south", S: "north", E: "west", W: "east" };
// The two crosswalks at a corner, by the way you'd walk: "ew" crosses the street running
// north–south (on a street page, that's "main"), "ns" the one running east–west ("cross").
const crossDir = (corner, n) => (n === "ew" ? OPP[corner[1]] : OPP[corner[0]]);
const ICON_N = { ew: "main", ns: "cross" };

// ------------------------------------------------------------ saved reports
function load() {
  try { return JSON.parse(localStorage.getItem(KEY)) || {}; } catch { return {}; }
}
const saved = load();
function persist() {
  try { localStorage.setItem(KEY, JSON.stringify(saved)); }
  catch { toast("This browser isn't saving reports (private browsing?). Send them before you close the page."); }
}
// Once the published data has a report this new for the intersection, the local copy has done its job.
for (const [k, r] of Object.entries(saved)) {
  const pub = H.checks?.[r.id];
  if (pub && pub.d >= r.date && pub.c?.[r.corner]) delete saved[k];
}
persist();
const keyOf = (id, corner) => `${id}|${corner}`;
const mineAt = id => CORNERS.map(c => saved[keyOf(id, c)]).filter(Boolean);
const coveredBy = v => (v === "none" || v === "no_corner" ? [] : (v || "").split("+").filter(Boolean));

// ------------------------------------------------------------ toast + copy
function toast(msg) {
  const t = document.getElementById("toast");
  t.textContent = msg;
  t.classList.add("show");
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => t.classList.remove("show"), 2400);
}
async function copy(text, what) {
  try { await navigator.clipboard.writeText(text); }
  catch {
    const ta = Object.assign(document.createElement("textarea"), { value: text });
    document.body.append(ta);
    ta.select();
    document.execCommand("copy");
    ta.remove();
  }
  if (what) toast(what);
}

// ------------------------------------------------------------ map
const params = new URLSearchParams(location.search);
const map = L.map("rmap", { preferCanvas: true, renderer: L.canvas({ tolerance: 10 }), maxZoom: 21, zoomControl: true });
L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
  maxZoom: 21, maxNativeZoom: 19,
  attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
}).addTo(map);
map.attributionControl.addAttribution("SDOT");

const DOT_ZOOM = 15;
const dotStyle = p => ({
  radius: 6, weight: p.rep || mineAt(p.id).length ? 3 : 1.5,
  color: p.rep || mineAt(p.id).length ? "#c2410c" : "#fff",
  fillColor: p.st === 2 ? "#111" : p.st === 1 ? "#1a8a4a" : "#999", fillOpacity: 1,
});
const dots = L.layerGroup(PTS.map(p => {
  const m = L.circleMarker([p.lat, p.lon], dotStyle(p));
  m.on("click", () => select(p.id, { pan: false }));
  m.bindTooltip(p.name, { direction: "top", offset: [0, -6] });
  p.marker = m;
  return m;
}));
const syncDots = () => (map.getZoom() >= DOT_ZOOM ? dots.addTo(map) : dots.remove());
map.on("zoomend", syncDots);
const ring = L.circleMarker([0, 0], { radius: 15, color: "#1f5fae", weight: 3, fill: false, interactive: false });

// ------------------------------------------------------------ location
// The phone's position lives only in this page's memory. A report keeps just the
// distance to the intersection and the fix's precision, rounded to 5 ft.
const gps = { fix: null, watch: null, layer: L.layerGroup().addTo(map), snapped: false };
const freshFix = () => (gps.fix && Date.now() - gps.fix.at < 120e3 ? gps.fix : null);
function nearest(lat, lng) {
  let best = null, bd = Infinity;
  for (const p of PTS) {
    const d = map.distance([lat, lng], [p.lat, p.lon]);
    if (d < bd) { bd = d; best = p; }
  }
  return [best, bd];
}
function locate() {
  if (!("geolocation" in navigator)) return toast("This browser can't share your location");
  gps.snapped = false;
  toast("Finding you…");
  if (gps.watch != null) navigator.geolocation.clearWatch(gps.watch);
  gps.watch = navigator.geolocation.watchPosition(pos => {
    const { latitude: lat, longitude: lng, accuracy } = pos.coords;
    gps.fix = { lat, lng, accuracy, at: Date.now() };
    gps.layer.clearLayers();
    L.circle([lat, lng], { radius: accuracy, color: "#1a73e8", weight: 1, fillOpacity: 0.1, interactive: false }).addTo(gps.layer);
    L.marker([lat, lng], { icon: L.divIcon({ className: "", html: '<div class="gps-dot"></div>', iconSize: [16, 16] }), interactive: false, keyboard: false }).addTo(gps.layer);
    if (!gps.snapped) {
      gps.snapped = true;
      const [p, d] = nearest(lat, lng);
      if (p && d < SNAP_M) { select(p.id, { zoom: 19 }); toast(`Found you at ${p.name}`); }
      else {
        map.setView([lat, lng], 18);
        toast(d < 2000 ? "No intersection right here. Tap the one you're at." : "You don't seem to be in Seattle. You can still pick an intersection.");
      }
    }
    renderWhere();
  }, err => {
    navigator.geolocation.clearWatch(gps.watch);
    gps.watch = null;
    toast(err.code === err.PERMISSION_DENIED
      ? "Location is blocked. Allow it for this site in your browser settings."
      : "Couldn't get your location. Try again outdoors.");
  }, { enableHighAccuracy: true, maximumAge: 5000, timeout: 20000 });
}
const LocateControl = L.Control.extend({
  options: { position: "topleft" },
  onAdd() {
    const wrap = L.DomUtil.create("div", "leaflet-bar");
    const b = L.DomUtil.create("a", "", wrap);
    b.href = "#";
    b.setAttribute("role", "button");
    b.title = b.ariaLabel = "Find the intersection I'm at";
    b.setAttribute("aria-label", b.title);
    b.innerHTML = `<svg width="18" height="18" viewBox="0 0 24 24" aria-hidden="true" style="margin-top:6px"><circle cx="12" cy="12" r="4" fill="currentColor"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3" stroke="currentColor" stroke-width="2" stroke-linecap="round"/><circle cx="12" cy="12" r="7.5" fill="none" stroke="currentColor" stroke-width="2"/></svg>`;
    L.DomEvent.disableClickPropagation(wrap);
    L.DomEvent.on(b, "click", e => { L.DomEvent.preventDefault(e); locate(); });
    return wrap;
  },
});
map.addControl(new LocateControl());

function onSite(p) {
  const fix = freshFix();
  if (!fix) return null;
  return {
    distance_ft: Math.round(map.distance([fix.lat, fix.lng], [p.lat, p.lon]) * FT / 5) * 5,
    accuracy_ft: Math.round(fix.accuracy * FT / 5) * 5,
  };
}

// ------------------------------------------------------------ state + URL
const state = { id: null, corner: "NW" };
function writeUrl() {
  const u = new URL(location.href);
  u.search = "";
  if (state.id) { u.searchParams.set("int", state.id); u.searchParams.set("corner", state.corner); }
  history.replaceState(null, "", u);
}
function select(id, { pan = true, zoom } = {}) {
  const p = byId.get(id);
  if (!p) return;
  const firstOpen = state.id !== id;
  state.id = id;
  if (firstOpen) {
    // Start on the first corner not yet reported.
    state.corner = CORNERS.find(c => !saved[keyOf(id, c)]) || "NW";
  }
  ring.setLatLng([p.lat, p.lon]).addTo(map);
  if (pan) map.setView([p.lat, p.lon], zoom || Math.max(map.getZoom(), 18));
  writeUrl();
  renderPanel();
}

// ------------------------------------------------------------ the panel
function publishedText(p) {
  const pub = H.checks?.[p.id];
  if (!pub) return "";
  const parts = Object.entries(pub.c).map(([corner, [ramps, issues]]) =>
    `${corner}: ${describe(corner, ramps, issues)}`);
  return `<p class="small">A neighbor reported this intersection${pub.on ? " in person" : ""} on ${esc(pub.d)}: ${esc(parts.join("; "))}.
    ${pub.on && pub.was !== p.st ? `Before that, the city's records said: ${STATUS[pub.was]}.` : ""}</p>`;
}
function whereText(p) {
  const fix = freshFix();
  if (!fix) return { cls: "", html: `<button class="btn locate" type="button" data-locate>📍 Use my location</button>
    <span class="small">so your report shows it was made on the spot. Only the distance is saved, never where you are.</span>` };
  const d = map.distance([fix.lat, fix.lng], [p.lat, p.lon]) * FT;
  const [near, nd] = nearest(fix.lat, fix.lng);
  if (d >= ON_SITE_FT && near && near.id !== p.id && nd * FT < ON_SITE_FT) {
    return { cls: "", html: `Your phone puts you at <strong>${esc(near.name)}</strong>, not here.
      <button class="link" type="button" data-select="${esc(near.id)}">Report that one instead</button>?` };
  }
  const ft = Math.round(d / 10) * 10;
  return d < ON_SITE_FT
    ? { cls: "here", html: `📍 You're here, about ${ft} ft from the middle of the intersection. Your reports will say so.` }
    : { cls: "", html: `Your phone puts you about ${ft.toLocaleString("en-US")} ft away, so reports here won't count as made on site.` };
}
function renderWhere() {
  const el = document.getElementById("where");
  if (!el || !state.id) return;
  const w = whereText(byId.get(state.id));
  el.className = `where ${w.cls}`;
  el.innerHTML = w.html;
}

function renderPanel() {
  const panel = document.getElementById("panel");
  if (!state.id) {
    panel.innerHTML = `
      <h2>Which intersection?</h2>
      <p>Standing at one? Your phone can find it.</p>
      <p><button class="btn locate" type="button" data-locate>📍 Use my location</button></p>
      <p class="small">Or zoom in on the map and tap an intersection's dot. Your location is only used on this page,
        to find the nearest intersection and how far you are from it. It's never saved or sent.</p>`;
    return;
  }
  const p = byId.get(state.id), c = state.corner, k = saved[keyOf(p.id, c)];
  const covered = k ? coveredBy(k.ramps_for) : ["ew", "ns"];
  const issues = issueList(k?.issues), noCorner = k?.ramps_for === "no_corner", noRamps = !!k && (noCorner || !covered.length);
  const box = (name, label, on, disabled, icon) => `<label class="check"><input type="checkbox" name="${name}"
    ${on ? "checked" : ""} ${disabled ? "disabled" : ""}>${icon}<span>${label}</span></label>`;
  const fake = { corner: c };
  const done = mineAt(p.id);
  const last = done.filter(x => x.corner !== c && x.ramps_for !== "no_corner").sort((a, b) => a.at - b.at).pop();
  const todo = CORNERS.filter(x => x !== c && !saved[keyOf(p.id, x)]);
  panel.innerHTML = `
    <h2>${esc(p.name)}</h2>
    <p class="small">The city's records: ${STATUS[p.st]}${p.sw ? "" : ", no sidewalk recorded"}.
      <a href="https://www.google.com/maps/@?api=1&map_action=pano&viewpoint=${p.lat},${p.lon}" target="_blank" rel="noopener">Street View</a></p>
    ${publishedText(p)}
    <p id="where" class="where"></p>
    <div class="plan">
      ${planSvg(p)}
      <div>
        <div class="corner-pick" role="group" aria-label="Corner">
          ${CORNERS.map(x => `<button type="button" data-corner="${x}" aria-pressed="${x === c}" class="${saved[keyOf(p.id, x)] ? "done" : ""}"
            aria-label="${CORNER_WORDS[x]} corner${saved[keyOf(p.id, x)] ? ", reported" : ""}">${x}</button>`).join("")}
        </div>
        <p class="small" style="max-width:12em">North is up. Tap a corner to report it.</p>
      </div>
    </div>
    <form data-report onsubmit="return false">
      <p><strong>${CORNER_WORDS[c][0].toUpperCase() + CORNER_WORDS[c].slice(1)} corner.</strong> Tick anything missing or wrong. Each tick is saved.</p>
      <div class="report-list">
        ${box("no_corner", "No corner here <span class=\"small\">(the flat side of a T, or no sidewalk)</span>", noCorner, false, noCornerIcon())}
        ${["ew", "ns"].map(n => box(`miss|${n}`, `No ramp to cross ${crossDir(c, n)}`, !!k && !noCorner && !covered.includes(n), noCorner,
          reportIcon("miss", fake, ICON_N[n]))).join("")}
        ${Object.entries(RAMP_ISSUES).map(([i, [label]]) => box(i, esc(label), issues.includes(i), noRamps, reportIcon(i, fake))).join("")}
      </div>
      <div class="buttons">
        <button class="button ${k && k.ramps_for === "ew+ns" && !issues.length ? "on" : ""}" type="button" data-action="ok">${reportIcon("ok", fake)}Nothing wrong here</button>
        ${last && !k ? `<button class="button" type="button" data-action="same" data-from="${last.corner}">Same as ${last.corner}</button>` : ""}
        ${k ? `<button class="button" type="button" data-action="clear">Clear</button>` : ""}
      </div>
      <label class="field">Note (optional)
        <input type="text" name="notes" maxlength="200" value="${esc(k?.notes || "")}" placeholder="e.g. a pole blocks the ramp"></label>
    </form>
    <p class="small">${k ? `Saved in this browser: ${esc(describe(c, k.ramps_for, k.issues))}.` : "Nothing saved for this corner yet."}
      ${todo.length ? `Next: ${todo.map(x => `<button class="link" type="button" data-corner="${x}">${x}</button>`).join(", ")}.`
        : `Every corner here is done. <a href="#mine-h">Send your reports</a>.`}</p>`;
  renderWhere();
}

function noCornerIcon() {
  return `<svg class="report-icon" width="32" height="32" viewBox="0 0 32 32" aria-hidden="true">
    <rect width="32" height="32" fill="${ICON.walk}"/><rect y="10" width="32" height="12" fill="${ICON.street}"/>
    <rect x="10" y="22" width="12" height="10" fill="${ICON.street}"/>
    <path d="M4,4L12,12M12,4L4,12" stroke="${ICON.ink}" stroke-width="1.8" stroke-linecap="round" opacity=".7"/></svg>`;
}

// A plan of the intersection, north up: each corner has a slot by each crosswalk,
// yellow for a ramp with a pad, gray without one, ✕ for no ramp, dashed until reported.
function planSvg(p) {
  const S = 220, A = 82, B = 138;
  const parts = [
    `<rect width="${S}" height="${S}" fill="var(--soft)"/>`,
    `<rect x="${A}" width="${B - A}" height="${S}" fill="var(--street)"/>`,
    `<rect y="${A}" width="${S}" height="${B - A}" fill="var(--street)"/>`,
    `<text x="${(A + B) / 2}" y="16" text-anchor="middle" class="compass">N ↑</text>`,
  ];
  for (const x of CORNERS) {
    const west = x.endsWith("W"), north = x.startsWith("N");
    const cx = west ? A : B, cy = north ? A : B, sx = west ? -1 : 1, sy = north ? -1 : 1;
    const k = saved[keyOf(p.id, x)], covered = k ? coveredBy(k.ramps_for) : [];
    const iss = issueList(k?.issues), noPad = iss.includes("no_warning"), diagonal = iss.includes("diagonal") && covered.length;
    parts.push(`<g data-corner="${x}" class="corner">
      <rect x="${west ? 2 : B + 2}" y="${north ? 2 : B + 2}" width="${A - 4}" height="${A - 4}" rx="6"
        fill="${k ? "var(--checked-soft)" : "transparent"}" ${x === state.corner ? 'stroke="var(--checked)" stroke-width="3"' : ""}/>
      <text x="${west ? A / 2 : B + A / 2}" y="${north ? A / 2 : B + A / 2}" dy=".35em" text-anchor="middle" class="corner-name"
        ${k?.ramps_for === "no_corner" ? 'opacity=".4"' : ""}>${x}</text></g>`);
    if (k?.ramps_for === "no_corner") continue;
    if (diagonal) {
      const ax = cx + sx * 12, ay = cy + sy * 12, turn = sx === sy ? -45 : 45;
      parts.push(`<rect x="${ax - 8}" y="${ay - 4}" width="16" height="8" transform="rotate(${turn} ${ax} ${ay})"
        fill="${noPad ? "#9a9a9a" : "#f2c200"}" stroke="var(--fg)" stroke-width="1"/>`);
    }
    for (const n of ["ew", "ns"]) {
      if (diagonal && covered.includes(n)) continue;
      // "ns" crosses the east–west street: its ramp sits on the horizontal curb. "ew" on the vertical one.
      const [w, h] = n === "ns" ? [22, 9] : [9, 22];
      const slide = diagonal ? 12 : 0;
      const rx = n === "ns" ? cx + sx * (8 + slide) + (sx < 0 ? -w : 0) : cx + (sx < 0 ? -w : 0);
      const ry = n === "ns" ? cy + (sy < 0 ? -h : 0) : cy + sy * (8 + slide) + (sy < 0 ? -h : 0);
      if (!k) parts.push(`<rect x="${rx}" y="${ry}" width="${w}" height="${h}" fill="none" stroke="var(--muted)" stroke-dasharray="3 2"/>`);
      else if (!covered.includes(n)) {
        const mx = rx + w / 2, my = ry + h / 2;
        parts.push(`<path d="M${mx - 6},${my - 6}L${mx + 6},${my + 6}M${mx + 6},${my - 6}L${mx - 6},${my + 6}" stroke="var(--fg)" stroke-width="3" stroke-linecap="round"/>`);
      } else parts.push(`<rect x="${rx}" y="${ry}" width="${w}" height="${h}" fill="${noPad ? "#9a9a9a" : "#f2c200"}" stroke="var(--fg)" stroke-width="1"/>`);
    }
  }
  return `<svg viewBox="0 0 ${S} ${S}" width="${S}" height="${S}" role="img"
    aria-label="Plan of the intersection, north up, ${CORNER_WORDS[state.corner]} corner selected">${parts.join("")}</svg>`;
}

// "no ramp to cross west, no yellow pad"
function describe(corner, ramps, issues) {
  if (ramps === "no_corner") return "no corner";
  const covered = coveredBy(ramps), list = issueList(issues);
  if (!covered.length) return "no ramps";
  const miss = ["ew", "ns"].filter(n => !covered.includes(n));
  const central = list.includes("diagonal");
  return [miss.length ? miss.map(n => `no ramp to cross ${crossDir(corner, n)}`).join(", ") : central ? "" : "ramps both ways",
    ...list.map(i => RAMP_ISSUES[i][1])].filter(Boolean).join(", ");
}

// ------------------------------------------------------------ saving
function save(p, corner, { missing = [], issues = [], noCorner = false, notes }) {
  const old = saved[keyOf(p.id, corner)];
  const covered = ["ew", "ns"].filter(n => !missing.includes(n));
  const ramps_for = noCorner ? "no_corner" : covered.length ? covered.join("+") : "none";
  saved[keyOf(p.id, corner)] = {
    id: p.id, name: p.name, lat: p.lat, lon: p.lon, corner,
    date: new Date().toLocaleDateString("en-CA"), // YYYY-MM-DD, local
    ramps_for, issues: ramps_for === "none" || noCorner ? "" : issues.join("+"),
    notes: notes ?? old?.notes ?? "",
    ...(onSite(p) || (old?.distance_ft != null ? { distance_ft: old.distance_ft, accuracy_ft: old.accuracy_ft } : {})),
    at: Date.now(),
  };
  after(p);
}
function after(p, focus) {
  persist();
  p.marker.setStyle(dotStyle(p));
  renderPanel();
  renderMine();
  if (focus) document.querySelector(`#panel [data-report] [name="${focus}"]`)?.focus();
}
function readForm(form) {
  const els = [...form.querySelectorAll("input[type=checkbox]")];
  return {
    noCorner: els.some(i => i.checked && i.name === "no_corner"),
    missing: els.filter(i => i.checked && i.name.startsWith("miss|")).map(i => i.name.slice(5)),
    issues: els.filter(i => i.checked && RAMP_ISSUES[i.name]).map(i => i.name),
    notes: form.querySelector("[name=notes]").value.trim().replace(/\s+/g, " "),
  };
}

const panel = document.getElementById("panel");
panel.addEventListener("change", e => {
  const form = e.target.closest("[data-report]");
  if (!form) return;
  const p = byId.get(state.id);
  save(p, state.corner, readForm(form));
  if (e.target.type === "checkbox") {
    document.querySelector(`#panel [data-report] [name="${CSS.escape(e.target.name)}"]`)?.focus();
    toast(`Saved (${Object.keys(saved).length} to send)`);
  }
});
document.addEventListener("click", e => {
  if (e.target.closest("[data-locate]")) {
    // From the header: bring the map up so the intersection it finds is in view.
    if (e.target.closest(".hero")) document.getElementById("rmap").scrollIntoView({ block: "start" });
    return locate();
  }
  const sel = e.target.closest("[data-select]");
  if (sel) return select(sel.dataset.select);
  const corner = e.target.closest("[data-corner]");
  if (corner && panel.contains(corner)) {
    state.corner = corner.dataset.corner;
    writeUrl();
    renderPanel();
    return panel.querySelector(`.corner-pick [data-corner="${state.corner}"]`)?.focus();
  }
  const b = e.target.closest("[data-action]");
  if (!b || !panel.contains(b)) return;
  const p = byId.get(state.id), c = state.corner;
  if (b.dataset.action === "ok") { save(p, c, {}); toast("Saved: nothing wrong here"); }
  if (b.dataset.action === "clear") { delete saved[keyOf(p.id, c)]; after(p); toast("Cleared"); }
  if (b.dataset.action === "same") {
    const from = saved[keyOf(p.id, b.dataset.from)];
    const missing = ["ew", "ns"].filter(n => !coveredBy(from.ramps_for).includes(n));
    save(p, c, { missing, issues: issueList(from.issues), notes: from.notes });
    toast(`Saved, same as ${b.dataset.from}`);
  }
});

// ------------------------------------------------------------ your reports + send
const csvCell = v => (/[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
const HEADER = "intersection_id,intersection,lat,lon,corner,date_checked,ramps_for,yellow_pad,ramp_issues,notes,distance_ft,accuracy_ft";
function byIntersection() {
  const groups = new Map();
  for (const r of Object.values(saved).sort((a, b) => a.at - b.at)) groups.set(r.id, [...(groups.get(r.id) || []), r]);
  for (const g of groups.values()) g.sort((a, b) => CORNERS.indexOf(a.corner) - CORNERS.indexOf(b.corner));
  return [...groups.values()];
}
function rowsCsv(groups) {
  return [HEADER, ...groups.flat().map(r => {
    const iss = issueList(r.issues), other = iss.filter(i => i !== "no_warning").join("+");
    const hasRamp = coveredBy(r.ramps_for).length > 0;
    const pad = !hasRamp ? "" : iss.includes("no_warning") ? "no" : "yes";
    return [r.id, r.name, r.lat, r.lon, r.corner, r.date, r.ramps_for, pad, other, r.notes || "", r.distance_ft ?? "", r.accuracy_ft ?? ""]
      .map(csvCell).join(",");
  })].join("\n");
}
function summary(g) {
  const byText = new Map();
  for (const r of g) {
    const t = describe(r.corner, r.ramps_for, r.issues);
    byText.set(t, [...(byText.get(t) || []), r.corner]);
  }
  return [...byText].map(([t, cs]) => `${t} at ${cs.length === 4 ? "all 4 corners" : cs.join(", ")}`).join("; ");
}
const onSiteText = g => {
  const d = g.map(r => r.distance_ft).filter(v => v != null);
  if (!d.length) return "location off";
  const min = Math.min(...d);
  return min < ON_SITE_FT ? `on site, about ${min} ft away` : `not on site (about ${min.toLocaleString("en-US")} ft away)`;
};
const pageUrl = id => `${location.origin}${location.pathname}?int=${encodeURIComponent(id)}`;
function issueBody(groups, csvInBody = true) {
  const notes = [...new Set(groups.flat().map(r => r.notes).filter(Boolean))];
  return [
    "<!-- Please don't include your name, phone, or email. -->",
    "",
    ...groups.map(g => `- **${g[0].name}**: ${summary(g)} (${onSiteText(g)})`),
    ...(notes.length ? ["", ...notes.map(n => `> ${n}`)] : []),
    "",
    "### Photos (optional)",
    "",
    "Drag photos of the corners here, or attach them from your phone.",
    "",
    "### Rows for `data/citywide-checks.csv`",
    "",
    ...(csvInBody ? ["```csv", rowsCsv(groups), "```"] : ["(Too long for a link: paste the report from your clipboard here.)"]),
    "",
    ...groups.map(g => `Map: ${pageUrl(g[0].id)}`),
  ].join("\n");
}
function issueUrl(groups) {
  const title = `Checked in person: ${groups.map(g => g[0].name).join("; ")}`.slice(0, 200);
  const build = csvIn => {
    const q = new URLSearchParams({ title, body: issueBody(groups, csvIn), labels: "field-check" });
    return `https://github.com/${REPO}/issues/new?${q.toString().replace(/\+/g, "%20")}`;
  };
  const full = build(true);
  return full.length < 7000 ? full : build(false);
}

function renderMine() {
  const groups = byIntersection(), n = Object.keys(saved).length;
  const count = document.getElementById("mine-count");
  count.hidden = !n;
  count.textContent = n;
  const el = document.getElementById("mine");
  if (!groups.length) {
    el.innerHTML = `<p>Nothing saved yet. Pick an intersection above and tick what you see.</p>`;
    return;
  }
  el.innerHTML = `
    <ul class="mine">${groups.map(g => `<li>
      <h3>${esc(g[0].name)}</h3>
      <p>${esc(summary(g))}.</p>
      <p class="small">${g.length} of 4 corners · ${esc(onSiteText(g))} ·
        <button class="link" type="button" data-select="${esc(g[0].id)}">Open</button> ·
        <button class="link" type="button" data-forget="${esc(g[0].id)}">Remove</button></p>
    </li>`).join("")}</ul>
    <p class="buttons">
      <a class="button primary" id="send" href="${esc(issueUrl(groups))}" target="_blank" rel="noopener">Send ${n} corner${n > 1 ? "s" : ""} as a GitHub issue</a>
      <button class="button" type="button" id="copy-report">Copy the report</button>
    </p>
    <p class="small">Send copies the report too, in case the GitHub app opens an empty issue: just paste it in.
      Once it's merged, the map shows it and this browser forgets it.</p>`;
}
document.getElementById("mine").addEventListener("click", e => {
  if (e.target.closest("#send") || e.target.closest("#copy-report")) {
    copy(issueBody(byIntersection()), e.target.closest("#send") ? "Report copied. If GitHub opens an empty issue, paste it in." : "Report copied");
    return;
  }
  const f = e.target.closest("[data-forget]");
  if (f && confirm("Remove your reports for this intersection from this browser?")) {
    for (const c of CORNERS) delete saved[keyOf(f.dataset.forget, c)];
    const p = byId.get(f.dataset.forget);
    if (p) after(p); else { persist(); renderMine(); }
  }
});

// ------------------------------------------------------------ boot
if (!PTS.length) {
  document.getElementById("panel").innerHTML = "<p>The intersection list hasn't been rebuilt with IDs yet. Try again after the next daily refresh.</p>";
} else {
  const startId = params.get("int");
  if (startId && byId.has(startId)) {
    if (CORNERS.includes(params.get("corner"))) state.corner = params.get("corner");
    const p = byId.get(startId);
    map.setView([p.lat, p.lon], 19);
    state.id = startId;
    ring.setLatLng([p.lat, p.lon]).addTo(map);
    renderPanel();
  } else {
    map.fitBounds([[47.495, -122.42], [47.735, -122.245]]);
    renderPanel();
  }
  syncDots();
}
renderMine();
