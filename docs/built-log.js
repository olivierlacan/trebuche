/* "Recently built": the changelog of curb ramps built in the last year, one entry per
 * intersection, saying what SDOT's records and neighbors each say. Drawn from build.rb's
 * built_log entries: a street's data.js (RAMPS.built_log) or every street's areas.js.
 *
 *   renderBuiltLog(el, entries, { days, summaryEl })
 * entries: built_log entries, each with `street` and `map` (link to that street's map.html)
 * added, and `area` (the neighborhood) to print it. days: the window build.rb used.
 * summaryEl: where to write the one-sentence tally. */
"use strict";

function renderBuiltLog(el, entries, { days = 365, summaryEl = null } = {}) {
  const esc = s => String(s ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  const day = iso => new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
  const span = (a, b, approx) => (approx ? a.slice(0, 4) : !b || a === b ? day(a) : `${day(a)} to ${day(b)}`);
  const plural = (n, w) => `${n} ${w}${n === 1 ? "" : "s"}`;
  const period = days % 365 === 0 ? (days === 365 ? "the last 12 months" : `the last ${days / 365} years`) : `the last ${days} days`;
  const yes = `<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="8" fill="var(--present)"/><path d="M5.2,9.2l2.6,2.6l5-5.2" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
  const half = `<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="7.2" fill="none" stroke="var(--partial)" stroke-width="1.6"/><path d="M9,1.8A7.2,7.2 0 0 1 9,16.2Z" fill="var(--partial)"/></svg>`;
  const no = `<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="7.2" fill="none" stroke="var(--muted)" stroke-width="1.6" stroke-dasharray="3 2.4"/></svg>`;

  const corners = entries.reduce((n, e) => n + e.corners.length, 0);
  const tally = k => entries.reduce((n, e) => n + (e.statuses[k] || 0), 0);
  if (summaryEl) {
    summaryEl.innerHTML = entries.length
      ? `In ${period}: <strong>${plural(corners, "corner")}</strong> at ${plural(entries.length, "intersection")}. ` +
        [[tally("confirmed"), "in SDOT's records and seen by a neighbor"],
         [tally("city"), "in SDOT's records, not checked in person yet"],
         [tally("work_closed"), "where SDOT closed a work order but hasn't recorded a ramp"],
         [tally("neighbor"), "seen by a neighbor, not in SDOT's records yet"]]
          .filter(([n]) => n).map(([n, t]) => `${n} ${t}`).join("; ") + "."
      : `Nothing built in ${period}, by SDOT's records or neighbors' reports.`;
  }
  if (!entries.length) {
    el.innerHTML = `<p class="built-empty">Seen new ramps? Open the corner on the map, choose <strong>Report what's here</strong>
      and tick <strong>Newly built</strong>, and it shows up here, even before the city records it.</p>`;
    return;
  }
  el.innerHTML = `<ol class="built-log">${entries.map(e => {
    const all = e.corners.length === 4 ? "All 4 corners" : `${e.corners.join(", ")} corner${e.corners.length > 1 ? "s" : ""}`;
    const link = `${e.map}?corner=${encodeURIComponent(`${e.intersection_id}-${e.corners[0]}`)}`;
    const n = e.corners.length, some = k => (k === n ? "" : ` (${k} of ${n} corners)`);
    const city = e.city_corners
      ? [yes, `<strong>SDOT's records:</strong> new ramps installed ${span(e.city_from, e.city_to, e.city_date_approx)}${some(e.city_corners)}` +
          (e.city_date_approx ? ` <span class="small">(SDOT gives the year only)</span>` : "")]
      : e.work_corners
        ? [half, `<strong>SDOT's records:</strong> it closed its work order here ${day(e.work_closed)}, but its ramp inventory doesn't show a new ramp yet`]
        : [no, `<strong>SDOT's records:</strong> not recorded yet`];
    const seen = e.seen_corners
      ? [yes, `<strong>In person:</strong> seen newly built by a neighbor, ${day(e.seen)}${some(e.seen_corners)}`]
      : [no, `<strong>In person:</strong> nobody has checked yet. <a href="${esc(link)}">Been there? Report it</a>`];
    const confirmed = e.statuses.confirmed === n;
    return `<li>
      <p class="when"><time datetime="${esc(e.date)}">${esc(e.city_date_approx && !e.seen_corners ? e.date.slice(0, 4) : day(e.date))}</time></p>
      <div>
        <h3><a href="${esc(link)}">${esc(e.street)} &amp; ${esc(e.cross_street)}</a>${confirmed ? ` <span class="tag">Confirmed</span>` : ""}</h3>
        <p class="small">${e.area ? `${esc(e.area)} · ` : ""}${all}${e.still_needed ? ` · ${plural(e.still_needed, "corner")} still ${e.still_needed === 1 ? "lacks" : "lack"} a ramp for a crossing` : ""}</p>
        <ul class="proof">${[city, seen].map(([icon, text]) => `<li>${icon}<span>${text}</span></li>`).join("")}</ul>
      </div>
    </li>`;
  }).join("")}</ol>`;
}
