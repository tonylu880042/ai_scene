import puppeteer from 'puppeteer-core'; import fs from 'fs';
const b = await puppeteer.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: 'new', args: ['--enable-unsafe-swiftshader'] });
const p = await b.newPage(); await p.setViewport({ width: 1920, height: 1080 });
await p.goto('http://localhost:8765/player_web/index.html?debug=1&frame=4080&autoplay=0&hud=0&pacers=6:30@40,5:45@62,6:15@72,6:30@84,6:00@110');
await new Promise(r => setTimeout(r, 6000));
const r = await p.evaluate(() => {
  const P = window.__player; const cv = document.getElementById('gl'); const out = {};
  const count = () => { const c = document.createElement('canvas'); c.width = cv.width; c.height = cv.height; const g = c.getContext('2d'); g.drawImage(cv, 0, 0); const d = g.getImageData(0, 0, c.width, c.height).data; let n = 0; for (let i = 3; i < d.length; i += 4) if (d[i] > 20) n++; return n; };
  // per-avatar visible pixel count with/without occluder (render each avatar alone)
  const res = [];
  for (let k = 0; k < P.pacers.length; k++) {
    P.pacers.forEach((a, j) => { a.av.root.visible = j === k; a.blob.visible = j === k; });
    P.occ.visible = true; P.renderer.render(P.scene, P.camera); const withOcc = count();
    P.occ.visible = false; P.renderer.render(P.scene, P.camera); const without = count();
    res.push({ name: P.pacers[k].spec.name, gap: +P.pacers[k].gap.toFixed(1), pxWithOccluder: withOcc, pxWithout: without, hiddenPct: +(100 * (1 - withOcc / Math.max(1, without))).toFixed(0) });
  }
  P.occ.visible = true; return res; });
console.log(JSON.stringify(r, null, 1)); await b.close();
