/* What a report can say about a curb ramp, and a small drawing for each. Shared by the
 * street maps (app.js) and the citywide report page (seattle/report/report.js). */
"use strict";

// What's wrong with ramps that are there. Stored as "no_warning+old_style" (ramp_issues column).
// [checkbox label, words in sentences]
const RAMP_ISSUES = {
  diagonal: ["Central ramp facing the middle of the intersection", "one central ramp aimed at the middle of the intersection"],
  no_warning: ["No yellow pad", "no yellow pad"],
  old_style: ["Older crisscross style", "older crisscross style"],
  damaged: ["Cracked or uneven", "cracked or uneven"],
  lip: ["Lip at street edge", "lip at the street edge"],
};
const issueList = v => (v || "").split("+").filter(k => RAMP_ISSUES[k]);

// ------------------------------------------------------------------ report icons
// One small drawing per thing a report can say, in the logo's style: a curb ramp seen
// from above, the street below it. Fixed colors (concrete, asphalt, yellow pad) read the
// same in light and dark mode. Decorative: the label next to each says it in words.
const ICON = { walk: "#d6d4cf", ramp: "#bdbab3", edge: "#7d7a74", street: "#5b5f66", pad: "#f2c200", ink: "#2a2a2a" };
function rampPlan({ pad = true, outline = !pad, extra = "" } = {}) {
  const dots = pad ? [12, 16, 20].flatMap(x => [19.4, 21.4].map(y => `<circle cx="${x}" cy="${y}" r=".75" fill="#8a6d00"/>`)).join("") : "";
  return `<rect width="32" height="23" fill="${ICON.walk}"/><rect y="23" width="32" height="9" fill="${ICON.street}"/>
    <polygon points="4,23 10,8 22,8 28,23" fill="${ICON.ramp}" stroke="${ICON.edge}" stroke-width=".8"/>
    ${pad ? `<rect x="9.5" y="18" width="13" height="5" fill="${ICON.pad}" stroke="${ICON.edge}" stroke-width=".5"/>${dots}`
      : outline ? `<rect x="9.5" y="18" width="13" height="5" fill="none" stroke="${ICON.ink}" stroke-width=".9" stroke-dasharray="1.6 1.2"/>` : ""}
    ${extra}`;
}
function reportIcon(kind, c, n) {
  let body;
  if (kind === "ok") {
    body = rampPlan() + `<circle cx="25.5" cy="6.5" r="5.5" fill="#1a7f45" stroke="#fff" stroke-width="1.2"/>
      <path d="M22.8,6.6l1.9,1.9l3.6,-3.7" fill="none" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>`;
  } else if (kind === "miss") {
    // The street to cross (with its crosswalk) and the ✕ on this corner's curb. Drawn for
    // a street running across, the corner above or below it; turned a quarter clockwise
    // for the main street, which moves "above" to the right (east) and "below" to the left.
    const above = n === "cross" ? c.corner.startsWith("N") : c.corner.endsWith("E");
    const bars = [9, 13, 17, 21].map(x => `<rect x="${x}" y="11.5" width="2" height="9" fill="#fff" opacity=".85"/>`).join("");
    const curbY = above ? 10 : 22, xy = above ? 5.5 : 26.5;
    body = `<rect width="32" height="32" fill="${ICON.walk}"/><rect y="10" width="32" height="12" fill="${ICON.street}"/>${bars}
      <line x1="0" x2="32" y1="${curbY}" y2="${curbY}" stroke="${ICON.edge}" stroke-width="1.2"/>
      <path d="M12.5,${xy - 3.5}L19.5,${xy + 3.5}M19.5,${xy - 3.5}L12.5,${xy + 3.5}" stroke="#c0392b" stroke-width="2.4" stroke-linecap="round"/>`;
    if (n === "main") body = `<g transform="rotate(90 16 16)">${body}</g>`;
  } else if (kind === "diagonal") {
    // A corner from above (sidewalk in the corner's quarter, streets on the other two
    // sides, a crosswalk across each), with one ramp at the curve aimed at the middle of
    // the intersection, between the crosswalks. Drawn for NW, turned for the others.
    const turn = { NW: 0, NE: 90, SE: 180, SW: 270 }[c.corner] || 0;
    const bars = [19, 23, 27].map(x => `<rect x="${x}" y="2" width="2" height="10" fill="#fff" opacity=".85"/>`).join("") +
      [19, 23, 27].map(y => `<rect x="2" y="${y}" width="10" height="2" fill="#fff" opacity=".85"/>`).join("");
    body = `<g transform="rotate(${turn} 16 16)"><rect width="32" height="32" fill="${ICON.street}"/>${bars}
      <path d="M0,0H17V6A11,11 0 0 1 6,17H0Z" fill="${ICON.walk}" stroke="${ICON.edge}" stroke-width=".9"/>
      <path d="M9.3,8.3L16.6,8.85A11,11 0 0 1 8.85,16.6L8.3,9.3Z" fill="${ICON.ramp}" stroke="${ICON.edge}" stroke-width=".6"/>
      <path d="M14.26,8.67L16.6,8.85A11,11 0 0 1 8.85,16.6L8.67,14.26A8.7,8.7 0 0 0 14.26,8.67Z" fill="${ICON.pad}"/>
      <path d="M17.5,17.5L25,25" stroke="#c0392b" stroke-width="1.8" stroke-linecap="round" stroke-dasharray="2.4 2"/>
      <path d="M26.6,21.4V26.6H21.4" fill="none" stroke="#c0392b" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></g>`;
  } else if (kind === "no_warning") {
    body = rampPlan({ pad: false });
  } else if (kind === "old_style") {
    const lines = [-8, -3, 2, 7, 12, 17, 22].map(d => `<path d="M${4 + d},23L${19 + d},8M${4 + d},8L${19 + d},23" stroke="${ICON.edge}" stroke-width=".7"/>`).join("");
    body = `<defs><clipPath id="ramp-clip"><polygon points="4,23 10,8 22,8 28,23"/></clipPath></defs>` +
      rampPlan({ pad: false, outline: false, extra: `<g clip-path="url(#ramp-clip)">${lines}</g>` });
  } else if (kind === "damaged") {
    body = rampPlan({ extra: `<path d="M11.5,8.5l2.5,3l-2,2.5l4,2.5" fill="none" stroke="${ICON.ink}" stroke-width="1.4" stroke-linejoin="round"/>
      <path d="M19,9.5l1.5,3l2,1" fill="none" stroke="${ICON.ink}" stroke-width="1"/>` });
  } else if (kind === "lip") {
    // Elevation, cropped at the shins: someone walking up from the street, the front toe
    // stopped by the step where the ramp meets the gutter (red), the back heel lifting,
    // both legs pitching forward. Back leg and shoe lighter, for depth.
    const shoe = fill => `<path d="M11,0H2C.4,0 -.3,-1 0,-2.2C.4,-3.6 2.2,-4 4.2,-4.3L7.4,-5.2C8.4,-6.6 9.7,-7 11,-7Z" fill="${fill}"/>
      <path d="M10.6,-.9H.8" stroke="#fff" stroke-width=".9" opacity=".75"/>`;
    body = `<rect width="32" height="32" fill="#eef0f2"/>
      <path d="M0,19L8,23V27H32V32H0Z" fill="${ICON.ramp}" stroke="${ICON.edge}" stroke-width=".8"/>
      <rect x="8" y="27" width="24" height="5" fill="${ICON.street}"/>
      <path d="M8,22.6V27.4" stroke="#c0392b" stroke-width="2.4" stroke-linecap="round"/>
      <path d="M23.4,19L16.5,-1" stroke="#7d93b3" stroke-width="5"/>
      <g transform="translate(19.5,27) rotate(-28) scale(.9)">${shoe("#6d6d6d")}</g>
      <path d="M16.4,21.8L12,-1" stroke="#3d5a80" stroke-width="5"/>
      <g transform="translate(8.2,27) scale(.9)">${shoe(ICON.ink)}</g>
      <path d="M5,17.5l-2.4,-1.2M5.8,15.1l-1.2,-2.3M8.2,14.3l-.1,-2.6" stroke="${ICON.ink}" stroke-width="1.1" stroke-linecap="round"/>`;
  }
  return `<svg class="report-icon" width="32" height="32" viewBox="0 0 32 32" aria-hidden="true">${body}</svg>`;
}
