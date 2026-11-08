// Accessibility scan: axe-core (WCAG 2.0, 2.1 and 2.2 A/AA, plus best practices) on every
// page and key interactive states, in light and dark mode, at desktop and phone widths.
//
//   cd docs && python3 -m http.server 8765 &      # serve the site
//   npm i --no-save axe-core@4.10.2 playwright    # once
//   node scripts/a11y-scan.js [page-filter]
//
// Known and accepted: target-size on map markers that overlap when zoomed out. WCAG 2.5.8's
// "equivalent" exception applies: every corner is also a button under "All corners", and
// every hotspot has a card with "Show on map".
const { chromium } = require('playwright');
const axe = require('fs').readFileSync(require.resolve('axe-core/axe.min.js'), 'utf8');
const BASE = process.env.BASE || 'http://localhost:8765/';
const PAGES = [
  '', 'seattle/', 'seattle/curb-ramps/', 'seattle/hotspots/', 'seattle/hotspots/?spot=3', 'ar/', 'ar/?area=green-lake&corner=82S-NE',
  ...['phinney-ridge', 'fremont', 'whittier-heights', 'loyal-heights', 'green-lake'].flatMap(s => [`seattle/${s}/`, `seattle/${s}/map.html`]),
  'seattle/phinney-ridge/map.html?corner=79-NE', 'seattle/phinney-ridge/map.html?tab=request',
  'seattle/phinney-ridge/map.html?tab=group&sel=79-NE,79-NW,64W-SW', 'seattle/phinney-ridge/map.html?tab=list',
  'seattle/report/', 'seattle/report/?int=78852&corner=NE',
];
const only = process.argv[2] ? PAGES.filter(p => p.includes(process.argv[2])) : PAGES;
(async () => {
  const b = await chromium.launch();
  const all = new Map();
  for (const scheme of ['light', 'dark']) for (const [vw, vh] of [[1280, 900], [390, 844]]) {
    const ctx = await b.newContext({ viewport: { width: vw, height: vh }, colorScheme: scheme });
    for (const path of only) {
      const p = await ctx.newPage();
      await p.goto(BASE + path, { waitUntil: 'networkidle' });
      await p.waitForTimeout(700);
      await p.addScriptTag({ content: axe });
      const r = await p.evaluate(() => axe.run(document, {
        runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa', 'wcag22aa', 'best-practice'] },
        resultTypes: ['violations'],
      }));
      for (const v of r.violations) for (const n of v.nodes) {
        const key = `${v.id} | ${path.split('?')[0]} | ${n.target.join(' ')}`;
        if (!all.has(key)) all.set(key, { id: v.id, impact: v.impact, help: v.help, page: path, target: n.target.join(' '),
          where: `${scheme} ${vw}`, msg: (n.any[0] || n.all[0] || n.none[0] || {}).message });
      }
      await p.close();
    }
    await ctx.close();
  }
  await b.close();
  const byRule = {};
  for (const v of all.values()) (byRule[v.id] ||= []).push(v);
  for (const [id, vs] of Object.entries(byRule)) {
    console.log(`\n## ${id} (${vs[0].impact}) x${vs.length}: ${vs[0].help}`);
    for (const v of vs.slice(0, 8)) console.log(`  - [${v.where}] ${v.page} :: ${v.target}\n      ${(v.msg || '').slice(0, 220)}`);
  }
  console.log(`\nTOTAL distinct: ${all.size}`);

})();
