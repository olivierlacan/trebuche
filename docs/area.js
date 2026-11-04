/* Landing page: live numbers and the corner strip, from data.js (window.RAMPS).
 * The marker drawing mirrors app.js so both pages look the same. */
"use strict";

const DATA = window.RAMPS;
const AREA = DATA.area;
const corners = DATA.corners;
const DAY = 864e5;
const today = Date.now();

// Same install-age colors as the map.
const GREEN = [26, 152, 80], YELLOW = [240, 200, 20], BROWN = [110, 62, 20];
const NO_DATE = "#c8c8c8";
const rgb = c => `rgb(${c.join(",")})`;
const mix = (a, b, t) => rgb(a.map((v, i) => Math.round(v + (b[i] - v) * Math.min(1, Math.max(0, t)))));
const oldest = DATA.city_ramps.map(r => r.installed).filter(Boolean).sort()[0];
const oldestAge = Math.max(730, (today - Date.parse(oldest)) / DAY);
function ageColor(iso) {
  if (!iso) return NO_DATE;
  const age = (today - Date.parse(iso)) / DAY;
  if (age <= 30) return rgb(GREEN);
  if (age <= 365) return mix(GREEN, YELLOW, (age - 30) / 335);
  return mix(YELLOW, BROWN, (age - 365) / (oldestAge - 365));
}

const kind = c => (c.confirmed_missing ? "x" : c.overall === "present" ? "ramp" : c.overall === "partial" ? "partial" : "q");
const WORDS = { NE: "northeast", NW: "northwest", SE: "southeast", SW: "southwest" };
const LABELS = { x: "no curb ramp", partial: "ramp for one crossing only", ramp: "ramps for both crossings", q: "not sure" };
const baseStreet = c => c.cross_street.replace(/\s*\(.*\)$/, "");

function mark(k, fill, s = 16) {
  const r = s / 2;
  const cross = (inset, w, halo) => {
    const a = s * inset, b = s * (1 - inset), d = `M${a},${a}L${b},${b}M${b},${a}L${a},${b}`;
    return (halo ? `<path d="${d}" stroke="var(--bg)" stroke-width="${w + 2.5}" stroke-linecap="round"/>` : "") +
      `<path d="${d}" stroke="${halo ? "var(--missing)" : "#000"}" stroke-width="${w}" stroke-linecap="round"/>`;
  };
  let body;
  if (k === "x") body = cross(0.2, Math.max(2.5, s * 0.16), true);
  else if (k === "q") body = `<circle cx="${r}" cy="${r}" r="${r - 1}" fill="#fff" stroke="#666" stroke-width="1.2"/>` +
    `<text x="${r}" y="${r}" dy=".36em" text-anchor="middle" font-size="${s * 0.66}" font-weight="700" font-family="system-ui,sans-serif" fill="#333">?</text>`;
  else body = `<circle cx="${r}" cy="${r}" r="${r - 1}" fill="${fill}" stroke="#fff" stroke-width="1.5"/>` +
    (k === "partial" ? cross(0.32, Math.max(1.6, s * 0.12), false) : "");
  return `<svg width="${s}" height="${s}" viewBox="0 0 ${s} ${s}" aria-hidden="true">${body}</svg>`;
}

// ------------------------------------------------------------ stats
const count = k => corners.filter(c => kind(c) === k).length;
const intersections = [...new Set(corners.map(c => c.intersection_id))];
const onHold = corners.filter(c => (c.sdot_projects || "").includes("on-hold"));
const filed = corners.filter(c => c.request_filed).length;
const mid = mix(GREEN, YELLOW, 0.5);

document.getElementById("stats-lede").textContent =
  `All ${corners.length} corners at ${intersections.length} intersections, checked against three public datasets.`;
const stats = [
  [count("x"), mark("x", null, 28), "corners with <strong>no curb ramp</strong>, confirmed by at least two sources"],
  [count("partial"), mark("partial", mid, 28), "corners with a ramp for <strong>only one</strong> of their two crossings"],
  [count("ramp"), mark("ramp", rgb(GREEN), 28), "corners with ramps for both crossings"],
  [onHold.length, `<svg width="28" height="28" aria-hidden="true"><circle cx="14" cy="14" r="11" fill="none" stroke="var(--planned)" stroke-width="3.5" stroke-dasharray="5 3"/></svg>`,
    "corners in an SDOT ramp project that's on hold"],
];
document.getElementById("stat-grid").innerHTML = stats.map(([n, icon, label]) =>
  `<div class="stat"><div class="n">${icon}<span>${n}</span></div><div class="label">${label}</div></div>`).join("");

if (onHold.length) {
  const where = [...new Set(onHold.map(baseStreet))].join(", ");
  const stillNeed = onHold.filter(c => c.overall === "missing" || c.overall === "partial").length;
  const wos = onHold.flatMap(c => c.work_orders || []).filter(w => (w.project || "").includes("on-hold"));
  const names = [...new Set(wos.map(w => `"${w.project}"`))].join(" and ");
  const since = wos.map(w => w.started).filter(Boolean).sort()[0];
  document.getElementById("goal-onhold").textContent =
    `${onHold.length} ${AREA.short} corners (at ${where}) are part of SDOT's ${names} project` +
    (since ? `, on hold since ${since.slice(0, 4)}` : "") +
    `, and ${stillNeed} of them still lack a ramp for at least one crossing. Asking the city to finish what it started is the quickest win.`;
}

// ------------------------------------------------------------ strip
const byInter = new Map();
for (const c of corners) {
  if (!byInter.has(c.intersection_id)) byInter.set(c.intersection_id, {});
  byInter.get(c.intersection_id)[c.corner] = c;
}
document.getElementById("strip").innerHTML = [...byInter].map(([id, q]) => {
  const any = Object.values(q)[0];
  const planned = Object.values(q).some(c => (c.work_orders || []).some(w => !w.closed));
  const cell = pos => {
    const c = q[pos];
    if (!c) return `<span></span>`;
    const label = `${WORDS[pos]} corner, ${AREA.street} & ${baseStreet(c)}: ${LABELS[kind(c)]}` +
      (c.corner_type !== "corner" ? " (side of a T-intersection)" : "");
    return `<a href="map.html?corner=${encodeURIComponent(c.corner_id.slice(AREA.id_prefix.length + 1))}" title="${label}" aria-label="${label}">` +
      `${mark(kind(c), ageColor(c.city_install_date), c.corner_type === "corner" ? 13 : 10)}</a>`;
  };
  return `<div class="col">
      <div class="quad">${["NW", "NE", "SW", "SE"].map(cell).join("")}</div>
      <div class="planned-mark" style="background:${planned ? "var(--planned)" : "transparent"}" ${planned ? `title="SDOT work planned at ${baseStreet(any)}"` : ""}></div>
      <div class="lbl">${id.replace(/[WE]$/, m => m.toLowerCase())}</div>
    </div>`;
}).join("");

document.getElementById("legend").innerHTML = [
  [mark("x", null), "No curb ramp"],
  [mark("partial", mid), "One crossing only"],
  [mark("ramp", mid), "Both crossings (color = install age)"],
  [mark("q", null), "Not sure"],
  [`<svg width="24" height="6" aria-hidden="true"><rect width="24" height="4" y="1" rx="2" fill="var(--planned)"/></svg>`, "SDOT work planned"],
].map(([svg, t]) => `<li>${svg}<span>${t}</span></li>`).join("") +
  jogNote();

// "64w/64e and 65w/65e are the two halves of Dayton's jogs", if the street jogs.
function jogNote() {
  const jogs = [...new Set(corners.map(c => c.intersection_id).filter(id => /W$/.test(id)).map(id => id.slice(0, -1)))];
  const halves = jogs.map(n => `${n}w/${n}e`);
  const list = halves.length > 1 ? `${halves.slice(0, -1).join(", ")} and ${halves.at(-1)}` : halves[0];
  return `<li class="small">Numbers are cross streets` +
    (jogs.length ? `; ${list} ${jogs.length > 1 ? "are" : "is"} the two halves of ${AREA.short}'s jog${jogs.length > 1 ? "s" : ""}` : "") + `.</li>`;
}

// ------------------------------------------------------------ freshness
const gen = (DATA.generated || "").slice(0, 10);
document.getElementById("refreshed").textContent =
  (gen ? `Data last refreshed ${gen}.` : "") + (filed ? ` ${filed} corner requests logged so far.` : "");
