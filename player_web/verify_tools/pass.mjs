import puppeteer from 'puppeteer-core';
const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new', args: ['--enable-unsafe-swiftshader'] });
const p = await b.newPage(); await p.setViewport({ width: 480, height: 270 });
await p.goto('http://localhost:8765/player_web/index.html?debug=1&frame=1000&autoplay=0&hud=0&pacers=5:30@-5,6:30@6');
await new Promise(r => setTimeout(r, 5000));
const r = await p.evaluate(async () => {
  const P = window.__player; const v = P.video; const out = []; let t0 = 1000 / 60;
  const prof = {};
  for (let k = 0; k < 1500; k++) {
    P.renderFrame(t0 + k / 60);
    P.pacers.forEach(a => { const c = P.camera.position, q = a.av.root.position; const dx = q.x - c.x, dz = q.z - c.z; const r = P.routeAt(P.state.userS); const d = a.gap;
      const key = a.spec.name; prof[key] = prof[key] || { minDist: 1e9, minAtGap: 0, lanes: [], jumps: 0, last: null };
      if (a.shown) { const dist = Math.hypot(dx, dz, q.y + 0.9 - c.y); if (dist < prof[key].minDist) { prof[key].minDist = dist; prof[key].minAtGap = d; }
        if (prof[key].last !== null) prof[key].jumps = Math.max(prof[key].jumps, Math.abs(a.laneNow - prof[key].last)); prof[key].last = a.laneNow; if (Math.abs(d) < 5) prof[key].lanes.push([+d.toFixed(1), +a.laneNow.toFixed(2)]); } });
  }
  const o = {}; for (const k in prof) o[k] = { minDist: +prof[k].minDist.toFixed(2), minAtGap: +prof[k].minAtGap.toFixed(2), maxLaneJumpPerFrame: +prof[k].jumps.toFixed(3), sample: prof[k].lanes.filter((_, i) => i % 15 == 0) };
  return o; });
console.log(JSON.stringify(r)); await b.close();
